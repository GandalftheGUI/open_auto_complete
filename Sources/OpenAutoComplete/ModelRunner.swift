import AppKit
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
        do {
            // Capture-by-value into the `container.perform` closure to work around
            // actor isolation: we read and later write persistent cache state here,
            // then return the updated cache/tokens for the actor to stash.
            let priorCache = persistentCache
            let priorTokens = cachedTokens

            let (rawOutput, newCache, newTokens) = try await container.perform {
                (ctx: ModelContext) -> (String, [KVCache]?, [Int]) in

                // Feed via chat messages so the processor applies Gemma's chat
                // template. Without it the model sees the whole prompt as one flat
                // string and leaks instruction fragments (".ou" from "You...")
                // back into the completion.
                let (systemMsg, userMsg) = Self.buildChatPrompt(from: context)
                let input = try await ctx.processor.prepare(input: UserInput(chat: [
                    .system(systemMsg),
                    .user(userMsg),
                ]))
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
                    // This chat template's turn-end marker ("<turn|>") isn't
                    // `tokenizer.eosTokenId` — the model reliably emits it right after a
                    // clean completion, but since skipSpecialTokens decodes it to "", it
                    // was invisible to every text-based stop check below, so generation
                    // ran straight past the model's own stopping point into hallucinated
                    // continuations ("tar" -> "<turn|>" -> "ouches of my life."). Detect
                    // any special/control token generically (skipSpecialTokens strips it)
                    // rather than hardcoding this one marker, since it may differ by model.
                    if piece != ctx.tokenizer.decode(tokenIds: [next], skipSpecialTokens: false) {
                        break
                    }
                    raw += piece
                    generated += 1
                    if raw.contains("\n") { break }
                    if Self.wordCount(raw) > 4 { break }
                    if raw.count > 60 { break }
                    if generated > 10 { break }
                    if ctx.tokenizer.eosTokenId.map({ $0 == next }) == true { break }
                    // Stop after sentence-ending punctuation so we don't run past a
                    // clean completion into hallucination ("liver.bedouit").
                    let trimmed = raw.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?") {
                        break
                    }
                }

                // Return updated cache state so the actor can retain it for next time.
                // The cache now contains the full prompt plus the generated tokens —
                // reusable for the next request whose prefix matches `fullTokens`.
                let processed = Self.applyWordBoundarySpacing(Self.postProcess(raw), context: context)
                return (processed, cacheToUse, fullTokens)
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

    /// Build a (system, user) pair for Gemma's chat template. System message holds
    /// the instruction + examples; user message is JUST the text to continue. Keeping
    /// the text-to-continue in its own role minimizes the chance of the model
    /// treating instruction text as part of the continuation.
    private static func buildChatPrompt(from context: String) -> (String, String) {
        let tail = String(context.suffix(300))
        let system = """
            You are an autocomplete engine. Output 1–4 more characters or words that \
            continue the user's text. Output ONLY the continuation — no quotes, no \
            explanation, no restating of the user's text.

            If the text ends mid-word, finish that word first (no leading space).
            If the text ends at a word boundary, start the next word (with a leading space).

            Examples:
            "I went to the store to buy" → " some milk"
            "The cat sat on the" → " mat"
            "I love playing the gui" → "tar"
            "My favorite color is blu" → "e"
            "She was tequ" → "ila"
            "Thanks for the" → " update"
            """
        return (system, tail)
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

    /// Inserts a leading space when `suggestion` glues a new word onto `context`
    /// without one. The system prompt asks the model to omit the leading space only
    /// when continuing the word already at the caret (e.g. "gui" → "tar") — but in
    /// practice it drops the space even when starting a genuinely new word about as
    /// often as not (e.g. "the" → "update", gluing into "theupdate"). Three layered
    /// signals, cheapest/most-certain first:
    ///
    /// 1. Clause/sentence punctuation ("no pizza!I don't" → "no pizza! I don't") is
    ///    essentially always followed by a space in prose — no ambiguity, just fix it.
    /// 2. A suggestion starting with an uppercase letter ("pizza" + "I" = "pizzaI")
    ///    is always a new word/sentence — nobody mid-word-completes into a capital
    ///    letter. This also sidesteps a real NSSpellChecker quirk: it's specifically
    ///    lenient about strings with an internal capital ("pizzaI" reads as
    ///    camelCase-ish and isn't flagged misspelled, unlike all-lowercase glues).
    /// 3. Otherwise, ask the actual question: does gluing the trailing/leading
    ///    word-fragments together with no space form a real English word? If so,
    ///    it's a legitimate mid-word completion ("gui"+"tar" = "guitar") and we
    ///    leave it alone; if not ("the"+"update" = "theupdate"), add the space back.
    ///    Explicitly pinned to en_US — checkSpelling's default language-autodetection
    ///    otherwise accepts short fragments that happen to be real words in another
    ///    installed dictionary ("gui" = mistletoe in French, "blu" = blue in Italian).
    private static let alwaysSpacedAfter: Set<Character> = [".", "!", "?", ";", ":", ","]

    private static func applyWordBoundarySpacing(_ suggestion: String, context: String) -> String {
        guard let lastContextChar = context.last, !lastContextChar.isWhitespace,
              let firstChar = suggestion.first, !firstChar.isWhitespace else {
            return suggestion
        }

        if alwaysSpacedAfter.contains(lastContextChar) {
            // Except thousands-separator commas ("3,000") — flanked by digits on
            // both sides, that's a number, not clause punctuation.
            if lastContextChar == ",",
               let beforeComma = context.dropLast().last, beforeComma.isNumber,
               firstChar.isNumber {
                return suggestion
            }
            return " " + suggestion
        }

        if firstChar.isUppercase {
            return " " + suggestion
        }

        let contextTailWord = context.reversed().prefix { $0.isLetter }.reversed()
        let suggestionLeadWord = suggestion.prefix { $0.isLetter }
        guard !contextTailWord.isEmpty, !suggestionLeadWord.isEmpty else { return suggestion }

        let candidate = String(contextTailWord) + String(suggestionLeadWord)
        let misspelledRange = NSSpellChecker.shared.checkSpelling(
            of: candidate, startingAt: 0, language: "en_US",
            wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
        )
        let isRealWord = misspelledRange.location == NSNotFound
        return isRealWord ? suggestion : " " + suggestion
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
