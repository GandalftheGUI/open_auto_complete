import Foundation
import MLXLMCommon
import MLXLLM
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Loads a local MLX-converted LLM on startup and serves short continuations on demand.
/// Thread-safety: all public methods are safe to call from any thread. Model load is
/// serialized internally; requests while loading are dropped with a "not ready" state.
actor ModelRunner {

    enum State {
        case idle
        case loading(progressFraction: Double)
        case ready
        case failed(String)
    }

    private(set) var state: State = .idle
    private var container: ModelContainer?
    private var activeTask: Task<Void, Never>?

    /// Resolved from `Settings.shared.modelId` on each load. User can change in the
    /// settings window; the change takes effect on the next app launch.
    private var modelConfig: ModelConfiguration {
        ModelConfiguration(id: Settings.shared.modelId)
    }

    /// Loads (or downloads if missing) the model into memory. Safe to call multiple
    /// times — subsequent calls after the first are no-ops until state resets.
    func loadIfNeeded() async {
        switch state {
        case .ready, .loading:
            return
        case .failed, .idle:
            break
        }

        state = .loading(progressFraction: 0)
        Log.shared.line("Model: starting load of \(modelConfig.name)")

        do {
            // The #huggingFaceLoadModelContainer macro expands to the new
            // factory.loadContainer(from:using:configuration:progressHandler:) signature
            // mlx-swift-lm main now requires, with a default Hub-backed Downloader and
            // TokenizerLoader pre-wired.
            let loaded = try await #huggingFaceLoadModelContainer(
                configuration: modelConfig,
                progressHandler: { progress in
                    Task { await self.updateProgress(progress.fractionCompleted) }
                }
            )
            self.container = loaded
            self.state = .ready
            Log.shared.line("Model: ✅ ready")
        } catch {
            self.state = .failed(String(describing: error))
            Log.shared.line("Model: ❌ \(error)")
        }
    }

    private func updateProgress(_ fraction: Double) {
        if case .loading = state {
            state = .loading(progressFraction: fraction)
        }
    }

    /// Produces a short continuation for `context`. Callers should debounce upstream
    /// so we aren't spammed on every keystroke. No busy-flag guard — a hung MLX
    /// inference must not lock out future requests.
    func suggest(context: String) async -> String? {
        guard case .ready = state, let container = container else {
            return nil
        }

        let tailForLog = String(context.suffix(80))
        Log.shared.line("LLM  ← context(\(context.count) chars, tail): \"\(Self.escape(tailForLog))\"")
        let t0 = Date()

        let text = await generate(using: container, context: context)

        let elapsed = Int(Date().timeIntervalSince(t0) * 1000)
        if let t = text {
            Log.shared.line("LLM  →  \(elapsed)ms  suggestion: \"\(Self.escape(t))\"")
        } else {
            Log.shared.line("LLM  →  \(elapsed)ms  suggestion: nil")
        }
        return text
    }

    /// Escape control chars so the log stays single-line and readable.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
    }

    private func generate(using container: ModelContainer, context: String) async -> String? {
        let prompt = Self.buildPrompt(from: context)

        do {
            let result = try await container.perform { (ctx: ModelContext) -> String in
                let input = try await ctx.processor.prepare(input: UserInput(prompt: prompt))

                // Temperature 0 → deterministic, best for short completions where we
                // don't want creative tangents.
                let parameters = GenerateParameters(temperature: 0, topP: 1.0)

                var raw = ""
                let stream = try MLXLMCommon.generate(
                    input: input,
                    parameters: parameters,
                    context: ctx
                )

                for await item in stream {
                    if Task.isCancelled { break }
                    switch item {
                    case .chunk(let piece):
                        raw += piece
                        // Bail early once we clearly have what we need.
                        if raw.contains("\n") { break }
                        if Self.wordCount(raw) > 6 { break }
                        if raw.count > 120 { break }
                    case .info, .toolCall:
                        break
                    }
                }
                return Self.postProcess(raw)
            }
            return result.isEmpty ? nil : result
        } catch {
            Log.shared.line("Model generate error: \(error)")
            return nil
        }
    }

    /// Autocomplete prompt. The trick with small instruct models is to frame this as
    /// a completion task, not a conversation — otherwise you get "Sure! Here's..."
    /// or ellipsis-prefixed poetry. We give it concrete examples of the format we
    /// want, which dramatically reduces chatty garbage output.
    private static func buildPrompt(from context: String) -> String {
        let tail = String(context.suffix(300))
        return """
            You complete the user's text with the next 1–4 words only. Output MUST be \
            just those words — no ellipsis, no quotes, no explanation, no restating.

            Example: "I went to the store to buy" → " some milk"
            Example: "The cat sat on the" → " mat"
            Example: "My favorite color is" → " blue"

            Complete this text:
            \(tail)
            """
    }

    /// Strip chatty preambles and leading punctuation garbage (ellipses, em-dashes),
    /// trim at the first newline, and hard-cap to 4 words. Leading whitespace is
    /// preserved so the continuation visually attaches to the user's existing text.
    private static func postProcess(_ s: String) -> String {
        var out = s

        // Trim at first newline.
        if let nl = out.firstIndex(of: "\n") { out = String(out[..<nl]) }

        // Strip leading/trailing quotes sometimes wrapped by the model.
        if out.hasPrefix("\"") || out.hasPrefix("“") { out.removeFirst() }
        if out.hasSuffix("\"") || out.hasSuffix("”") { out.removeLast() }

        // Strip common chatty preambles.
        let preambles = [
            "Continuation: ", "continuation: ",
            "Sure, ", "Sure! ", "Of course, ", "Of course! ",
            "Here's ", "Here is ", "Here are ",
        ]
        for p in preambles where out.hasPrefix(p) {
            out = String(out.dropFirst(p.count))
            break
        }

        // Strip leading ellipsis / em-dash / bullet garbage that Gemma 3 likes to add.
        // Preserves one space after stripping so the word starts cleanly.
        let leadJunk: [Character] = [".", "…", "–", "—", "•", "*", "-"]
        while let first = out.first, leadJunk.contains(first) {
            out.removeFirst()
        }

        // Hard-cap to 4 words, preserving leading whitespace.
        return firstNWords(out, n: 4)
    }

    /// Returns up to the first `n` words of `s`, keeping any leading whitespace.
    private static func firstNWords(_ s: String, n: Int) -> String {
        var result = ""
        var wordsSeen = 0
        var inWord = false
        for ch in s {
            if ch.isWhitespace {
                inWord = false
                result.append(ch)
            } else {
                if !inWord {
                    if wordsSeen == n { break }
                    wordsSeen += 1
                    inWord = true
                }
                result.append(ch)
            }
        }
        return result
    }

    private static func wordCount(_ s: String) -> Int {
        var count = 0
        var inWord = false
        for ch in s {
            if ch.isWhitespace {
                inWord = false
            } else if !inWord {
                count += 1
                inWord = true
            }
        }
        return count
    }
}
