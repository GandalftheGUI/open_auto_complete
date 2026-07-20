import Cocoa

if CommandLine.arguments.contains("--probe") || CommandLine.arguments.contains("--test") {
    // Blocking the main thread on a semaphore here would deadlock: Foundation's
    // networking (used by the Hugging Face downloader) dispatches completions back
    // to the main queue, which only runs if the run loop is actually being pumped.
    Task {
        if CommandLine.arguments.contains("--test") {
            await SuggestionTests.run()
        } else {
            await SuggestionProbe.run()
        }
        exit(0)
    }
    RunLoop.main.run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
