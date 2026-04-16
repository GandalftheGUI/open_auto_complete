import Foundation
import MLX
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

    /// Persistent KV cache across model requests. Enables reusing the prefill
    /// compute for the shared prefix of the previous prompt and the current one.
    /// When invalidated (cache miss, or prompt diverged), this is discarded.
    private var persistentCache: [KVCache]?
    private var cachedTokens: [Int] = []

    /// Monotonic request id. Every `suggest()` call bumps it; mid-flight generations
    /// check against it between tokens and bail if they've been superseded. This is
    /// how we achieve "fire on every keystroke, cancel the previous" without needing
    /// MLX-level cancellation (which doesn't exist for prefill).
    private var currentRequestId: Int = 0

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

    /// Produces a short continuation for `context`. Each call bumps `currentRequestId`;
    /// earlier in-flight calls detect this between decoded tokens and bail out early,
    /// so the newest keystroke always wins without serializing behind stale work.
    func suggest(context: String) async -> String? {
        guard case .ready = state, let container = container else {
            return nil
        }

        currentRequestId += 1
        let myId = currentRequestId

        let tailForLog = String(context.suffix(80))
        Log.shared.line("LLM  ← [#\(myId)] context(\(context.count) chars, tail): \"\(Self.escape(tailForLog))\"")
        let t0 = Date()

        let text = await generate(using: container, context: context, requestId: myId)

        let elapsed = Int(Date().timeIntervalSince(t0) * 1000)
        if let t = text {
            Log.shared.line("LLM  →  [#\(myId)] \(elapsed)ms  suggestion: \"\(Self.escape(t))\"")
        } else {
            Log.shared.line("LLM  →  [#\(myId)] \(elapsed)ms  nil (superseded or empty)")
        }
        return text
    }

    /// True iff `id` is still the most recent request.
    private func isCurrent(_ id: Int) -> Bool { id == currentRequestId }

    /// Escape control chars so the log stays single-line and readable.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
    }

    private func generate(using container: ModelContainer, context: String, requestId: Int) async -> String? {
        let prompt = Self.buildPrompt(from: context)

        do {
            // Capture-by-value into the `container.perform` closure to work around
            // actor isolation: we read and later write persistent cache state here,
            // then return the updated cache/tokens for the actor to stash.
            let priorCache = persistentCache
            let priorTokens = cachedTokens

            let (rawOutput, newCache, newTokens) = try await container.perform {
                (ctx: ModelContext) -> (String, [KVCache]?, [Int]) in

                // Tokenize the new prompt using the model's own processor.
                let input = try await ctx.processor.prepare(input: UserInput(prompt: prompt))
                let fullTokens: [Int] = input.text.tokens.asArray(Int.self)

                // Common prefix between last and current prompts. We only keep shared
                // cache state if it matches the tokenized prefix exactly.
                let sharedPrefix = Self.commonPrefixLength(priorTokens, fullTokens)

                // Decide cache reuse path. If the shared prefix is "meaningful"
                // (≥16 tokens) and we have a prior cache whose offset matches that
                // prefix, we trim it and feed only the new tail to the iterator.
                // Otherwise start fresh.
                // repetitionPenalty > 1 discourages the model from re-emitting
                // recently-generated tokens. Without it, greedy decoding (temp=0)
                // can fall into "memoriesigaigaiga" / "Mexicoгугугу" loops.
                var parameters = GenerateParameters(temperature: 0, topP: 1.0)
                parameters.repetitionPenalty = 1.15
                parameters.repetitionContextSize = 20
                let cacheToUse: [KVCache]
                let tailTokens: [Int]

                // Guard: always leave at least one token to feed the TokenIterator.
                // If the new prompt is a pure prefix/equal to the cached prompt,
                // shared would equal fullTokens.count and we'd pass an empty tail,
                // which MLX rejects with a reshape-of-empty-array fatal.
                let maxShared = max(0, fullTokens.count - 1)
                let effectiveShared = min(sharedPrefix, maxShared)

                if effectiveShared >= 16,
                   let prior = priorCache,
                   let priorOffset = prior.first?.offset,
                   priorOffset >= effectiveShared {
                    // Trim each cache layer down to exactly `effectiveShared` entries.
                    for layer in prior {
                        layer.trim(priorOffset - effectiveShared)
                    }
                    cacheToUse = prior
                    tailTokens = Array(fullTokens[effectiveShared...])
                    Log.shared.line("KV reuse: shared=\(effectiveShared) tokens, prefilling only \(tailTokens.count)")
                } else {
                    cacheToUse = ctx.model.newCache(parameters: parameters)
                    tailTokens = fullTokens
                    Log.shared.line("KV miss: prefilling full prompt (\(fullTokens.count) tokens)")
                }

                // Build a TokenIterator on the (possibly trimmed) tail and the cache.
                let tailArray = MLXArray(tailTokens.map { Int32($0) })
                let lmInput = LMInput(text: .init(tokens: tailArray))
                var iterator = try TokenIterator(
                    input: lmInput,
                    model: ctx.model,
                    cache: cacheToUse,
                    parameters: parameters
                )

                // Pull up to 6 tokens or until early-stop conditions. Between tokens
                // we check if this request has been superseded — bail early if so.
                var raw = ""
                var generated = 0
                while let next = iterator.next() {
                    if !(await self.isCurrent(requestId)) {
                        Log.shared.line("gen [#\(requestId)] cancelled mid-decode (superseded)")
                        break
                    }
                    let piece = ctx.tokenizer.decode(tokenIds: [next], skipSpecialTokens: true)
                    raw += piece
                    generated += 1
                    if raw.contains("\n") { break }
                    if Self.wordCount(raw) > 6 { break }
                    if raw.count > 120 { break }
                    if generated > 24 { break }
                    if ctx.tokenizer.eosTokenId.map({ $0 == next }) == true { break }
                }

                // Return updated cache state so the actor can retain it for next time.
                // The cache now contains the full prompt plus the generated tokens —
                // reusable for the next request whose prefix matches `fullTokens`.
                return (Self.postProcess(raw), cacheToUse, fullTokens)
            }

            // Persist the cache and the prompt-token-list for the next call.
            self.persistentCache = newCache
            self.cachedTokens = newTokens
            return rawOutput.isEmpty ? nil : rawOutput
        } catch {
            Log.shared.line("Model generate error: \(error)")
            // Invalidate cache on error so next request starts clean.
            self.persistentCache = nil
            self.cachedTokens = []
            return nil
        }
    }

    /// Length of the longest token sequence that appears at the start of both
    /// `a` and `b`. Used to decide how much KV cache we can reuse.
    private static func commonPrefixLength(_ a: [Int], _ b: [Int]) -> Int {
        let n = min(a.count, b.count)
        var i = 0
        while i < n && a[i] == b[i] { i += 1 }
        return i
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
