import Foundation

/// Headless harness for iterating on suggestion quality without any GUI, AX, or
/// event-tap involvement. Feeds a batch of hand-written contexts straight into
/// ModelRunner.suggest(context:) and prints the raw results, so prompt/postprocess
/// changes can be evaluated without needing real keystrokes in a real text field.
///
/// Run with: .build/release/OpenAutoComplete --probe [file-with-one-context-per-line]
enum SuggestionProbe {
    static func run() async {
        // Piped stdout is fully buffered by default, so nothing appears until the
        // buffer fills or the process exits — unbuffer it so progress streams live.
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

        for context in loadContexts() {
            let suggestion = await runner.suggest(context: context)
            let display = suggestion.map { "\"\($0)\"" } ?? "nil"
            print("CONTEXT:    \"\(context)\"")
            print("SUGGESTION: \(display)")
            print("COMBINED:   \"\(context)\(suggestion ?? "")\"")
            print(String(repeating: "-", count: 60))
        }
    }

    /// A file path may be passed as the argument right after `--probe` (one context
    /// per line). Falls back to a small built-in batch covering common cases: mid-word
    /// completion, word-boundary continuation, punctuation, and short/ambiguous input.
    private static func loadContexts() -> [String] {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--probe"), idx + 1 < args.count,
           let contents = try? String(contentsOfFile: args[idx + 1], encoding: .utf8) {
            return contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
        return defaultContexts
    }

    private static let defaultContexts: [String] = [
        "I love playing the guitar",
        "I love playing the gui",
        "Thanks for the",
        "I went to the store to buy",
        "The weather today is",
        "My favorite color is blu",
        "She was tequ",
        "I think we should",
        "Can you send me the",
        "Let's meet up tomorrow at",
        "The meeting is scheduled for",
        "I really appreciate",
    ]
}
