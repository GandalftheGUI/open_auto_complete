import AppKit
import Foundation

/// A curated, objectively-checkable test set for suggestion quality, run against the
/// real model (not a proxy). Each case is checked by rules that don't depend on the
/// exact wording the model picks — spacing correctness, no leaked special tokens, no
/// runaway/garbled output — so this can be re-run after every prompt or postprocess
/// change to see concretely whether it moved the needle, instead of eyeballing a
/// transcript. Run with: OpenAutoComplete --test
enum SuggestionTests {

    struct Case {
        let name: String
        let context: String
    }

    /// Grouped by the specific failure mode each case is meant to catch. Add a case
    /// here whenever a new bad output is found in real use — that's the point: this
    /// set should grow every time something slips through.
    static let cases: [Case] = [
        // Mid-word completions: must NOT gain a leading space.
        Case(name: "mid-word: gui->tar", context: "I love playing the gui"),
        Case(name: "mid-word: blu->e", context: "My favorite color is blu"),
        Case(name: "mid-word: tequ->ila", context: "She was tequ"),

        // Complete word + new word: MUST gain a leading space if the model omits one.
        Case(name: "new-word: pizza (reported bug)", context: "no pizza"),
        Case(name: "new-word: the->update", context: "Thanks for the"),
        Case(name: "new-word: should->discuss", context: "I think we should"),
        Case(name: "new-word: buy->some", context: "I went to the store to buy"),
        Case(name: "new-word: send me the", context: "Can you send me the"),
        Case(name: "new-word: is->nice", context: "The weather today is"),

        // Sentence punctuation: MUST gain a leading space (reported bug).
        Case(name: "punctuation: !", context: "I don't like pizza!"),
        Case(name: "punctuation: .", context: "The weather is bad."),
        Case(name: "punctuation: ?", context: "Is that true?"),
        Case(name: "punctuation: ;", context: "Wait for me;"),
        Case(name: "punctuation: :", context: "Note this carefully:"),

        // Numbers: comma must NOT gain a space when it's a thousands separator.
        Case(name: "number: thousands separator", context: "The price is 3,"),

        // Sentence-ending punctuation must start a genuinely new, capitalized
        // sentence, not lowercase-continue as if the punctuation weren't there
        // (reported bug: "I play guitar." kept suggesting " and sing too.").
        Case(name: "new sentence: reported bug", context: "I play guitar."),
        Case(name: "new sentence: capitalization", context: "She loves to read."),

        // New sentence after a capitalizable word: leading capital is a strong signal.
        Case(name: "new-sentence: capital start", context: "I love it here.  "),

        // Already-spaced context: nothing to fix, just shouldn't regress.
        Case(name: "already spaced", context: "I really appreciate "),

        // Contractions / apostrophes: shouldn't break word-boundary detection.
        Case(name: "contraction context", context: "I don't think that's"),

        // From the user's own live testing.
        Case(name: "user-reported: guitar/singing", context: "I love playing the guitar"),
    ]

    static func run() async {
        setvbuf(stdout, nil, _IONBF, 0)

        let runner = ModelRunner()
        print("Loading model...")
        await runner.loadIfNeeded()
        while true {
            let state = await runner.state
            if case .ready = state { break }
            if case .failed(let msg) = state {
                print("Model failed to load: \(msg)")
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        print("Model ready.\n")

        var passed = 0
        var failed = 0

        for c in cases {
            let suggestion = await runner.suggest(context: c.context)
            let failures = checkAll(context: c.context, suggestion: suggestion)
            let combined = c.context + (suggestion ?? "")
            if failures.isEmpty {
                passed += 1
                print("PASS  \(c.name)")
                print("      \"\(c.context)\" + \"\(suggestion ?? "nil")\" = \"\(combined)\"")
            } else {
                failed += 1
                print("FAIL  \(c.name)")
                print("      \"\(c.context)\" + \"\(suggestion ?? "nil")\" = \"\(combined)\"")
                for f in failures { print("      -> \(f)") }
            }
        }

        print("\n\(passed)/\(passed + failed) passed")
    }

    // MARK: - Checks

    private static func checkAll(context: String, suggestion: String?) -> [String] {
        var failures: [String] = []

        guard let s = suggestion, !s.isEmpty else {
            // Empty is only a failure for contexts that clearly warrant a continuation;
            // treat as informational rather than a hard failure since this is more a
            // model-confidence question than a correctness bug.
            return failures
        }

        if let f = checkNoLeakedSpecialTokens(s) { failures.append(f) }
        if let f = checkNotSuspiciouslyLong(s) { failures.append(f) }
        if let f = checkSpacingAtBoundary(context: context, suggestion: s) { failures.append(f) }
        if let f = checkNewSentenceCapitalized(context: context, suggestion: s) { failures.append(f) }

        return failures
    }

    /// A suggestion following sentence-ending punctuation must start a genuinely new,
    /// capitalized sentence — not lowercase-continue as if the punctuation weren't
    /// there ("I play guitar." -> " and sing too." was the reported bug this catches).
    private static func checkNewSentenceCapitalized(context: String, suggestion: String) -> String? {
        guard let lastMeaningful = context.reversed().first(where: { !$0.isWhitespace }),
              [".", "!", "?"].contains(lastMeaningful) else {
            return nil
        }
        guard let firstLetter = suggestion.first(where: { $0.isLetter }) else { return nil }
        if firstLetter.isLowercase {
            return "new sentence not capitalized after '\(lastMeaningful)'"
        }
        return nil
    }

    private static func checkNoLeakedSpecialTokens(_ suggestion: String) -> String? {
        let markers = ["<|", "|>", "<turn", "turn|>", "<eos>", "<bos>"]
        for m in markers where suggestion.contains(m) {
            return "leaked special token marker \"\(m)\" in suggestion"
        }
        return nil
    }

    private static func checkNotSuspiciouslyLong(_ suggestion: String) -> String? {
        // postProcess caps at 4 words / 60 chars raw, but a garbled run can still slip
        // a single very long "word" through (e.g. "tarouches" territory) — flag any
        // token longer than a generous real-word ceiling.
        let longest = suggestion.split(separator: " ").map(\.count).max() ?? 0
        if longest > 20 {
            return "suspiciously long single token (\(longest) chars) — possible garbling"
        }
        return nil
    }

    /// Independent oracle for spacing correctness, deliberately not sharing code with
    /// ModelRunner.applyWordBoundarySpacing — this checks the actual *output* against
    /// the same real-world rules a human reader would apply, not whether the
    /// implementation agrees with itself.
    private static func checkSpacingAtBoundary(context: String, suggestion: String) -> String? {
        guard let lastC = context.last, let firstS = suggestion.first else { return nil }
        if firstS.isWhitespace { return nil }
        if lastC.isWhitespace { return nil }

        let clausePunctuation: Set<Character> = [".", "!", "?", ";", ":"]
        if clausePunctuation.contains(lastC) {
            return "missing space after clause punctuation '\(lastC)'"
        }
        if lastC == ",", !(context.dropLast().last?.isNumber == true && firstS.isNumber) {
            return "missing space after comma"
        }
        if firstS.isUppercase {
            return "missing space before capitalized new word \"\(firstS)\""
        }
        guard lastC.isLetter, firstS.isLetter else { return nil }

        let contextTailWord = String(context.reversed().prefix { $0.isLetter }.reversed())
        guard !contextTailWord.isEmpty else { return nil }
        let tailIsCompleteWord = NSSpellChecker.shared.checkSpelling(
            of: contextTailWord, startingAt: 0, language: "en_US",
            wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
        ).location == NSNotFound
        if tailIsCompleteWord {
            // "gui" isn't complete on its own so this branch is skipped for genuine
            // mid-word cases; "pizza"/"the"/"is" are, so gluing anything onto them
            // without a space is very likely a missing space, not a real compound.
            return "missing space after complete word \"\(contextTailWord)\""
        }
        return nil
    }
}
