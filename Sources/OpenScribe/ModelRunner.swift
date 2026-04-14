import Foundation
import Hub
import MLXLMCommon
import MLXLLM

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

    /// The model we ship with for M4a. Tiering comes next.
    /// Gemma 3 4B 8-bit: ~4.5 GB download, ~6 GB resident. The 4-bit variant's
    /// quantization layout isn't compatible with mlx-swift-examples 2.29.1's Gemma
    /// loader; the 8-bit variant uses a different packing that does load.
    private let modelConfig = ModelConfiguration(
        id: "mlx-community/gemma-3-4b-it-8bit"
    )

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
            // Force online mode: swift-transformers' NetworkMonitor misdetects some
            // environments (our sandbox/entitlement setup) as offline and throws
            // offlineModeError before even attempting a download.
            let hub = HubApi(useOfflineMode: false)
            let loaded = try await LLMModelFactory.shared.loadContainer(
                hub: hub,
                configuration: modelConfig
            ) { progress in
                Task { await self.updateProgress(progress.fractionCompleted) }
            }
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

    /// Produces a short continuation for `context`. Returns nil if the model isn't ready
    /// or generation fails. Cancels any in-flight generation before starting a new one.
    func suggest(context: String) async -> String? {
        guard case .ready = state, let container = container else {
            return nil
        }

        // Cancel any in-flight task so only the most recent request matters.
        activeTask?.cancel()

        let tailForLog = String(context.suffix(80))
        Log.shared.line("LLM  ← context(\(context.count) chars, tail): \"\(Self.escape(tailForLog))\"")
        let t0 = Date()

        return await withCheckedContinuation { continuation in
            let task = Task {
                let text = await self.generate(using: container, context: context)
                let elapsed = Int(Date().timeIntervalSince(t0) * 1000)
                if let t = text {
                    Log.shared.line("LLM  →  \(elapsed)ms  suggestion: \"\(Self.escape(t))\"")
                } else {
                    Log.shared.line("LLM  →  \(elapsed)ms  suggestion: nil")
                }
                continuation.resume(returning: text)
            }
            self.activeTask = task
        }
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

    /// Autocomplete prompt. Few-shot format works better than a single-message
    /// instruction for small chat-tuned models — it steers them away from the
    /// "Sure! Here's a continuation…" conversational habit.
    private static func buildPrompt(from context: String) -> String {
        let tail = String(context.suffix(400))
        return """
            You are an autocomplete engine. Output ONLY 1–4 words that would naturally \
            come next after the user's text. Preserve leading whitespace if needed. No \
            quotes, no preamble, no explanation, no repetition of the user's text.

            Example 1:
            Text: "I went to the store to buy"
            Continuation: " some milk"

            Example 2:
            Text: "The quick brown fox"
            Continuation: " jumps over"

            Example 3:
            Text: "Thanks for the"
            Continuation: " update"

            Text: "\(tail)"
            Continuation:
            """
    }

    /// Strip chatty preambles the model may add despite instructions, trim at the
    /// first newline, and hard-cap to 4 words. Leading whitespace is preserved so the
    /// continuation visually attaches to the user's existing text.
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
