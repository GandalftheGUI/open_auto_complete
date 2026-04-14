import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var eventTap: EventTap?
    private var overlay: Overlay?
    private var tracker: Timer?
    private var mousePressed = false

    private let runner = ModelRunner()

    // Last context we asked the model about; prevents firing duplicate requests when
    // the caret hasn't meaningfully changed.
    private var lastRequestedContext: String = ""

    // Set whenever a suggestion is currently displayed. Nil means the overlay is
    // hidden. Tab commits `currentSuggestion`; Escape dismisses it.
    private var currentSuggestion: String?

    // Marker we stamp on every synthesized CGEvent so our own tap can recognize
    // and pass-through events we posted ourselves (otherwise we'd process each
    // committed character as a fresh user keystroke and create a feedback loop).
    private let synthesizedMarker: Int64 = 0x4F5343_00000000  // "OSC\0..."

    // Backward-nav tracking: remember where the caret was last seen (per app) so we
    // can hide the overlay the moment the user moves the cursor backward.
    private var prevCaretOffset: Int = -1
    private var prevBundleId: String = ""
    private var hiddenByBackwardNav = false

    /// Used as a fallback while the model is still loading / downloading.
    private let placeholderSuggestion = "(model loading…)"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.shared.line("OpenScribe launched.  exec=\(Bundle.main.executablePath ?? "?")")
        Log.shared.line("Logging to: \(Log.shared.path)")

        installStatusItem()

        guard Permissions.ensureAccessibility() else {
            Log.shared.line("Accessibility: ❌ not granted — showing alert and quitting.")
            showAccessibilityAlertAndQuit()
            return
        }
        Log.shared.line("Accessibility: ✅")

        overlay = Overlay()

        do {
            let tap = try EventTap.install(
                events: [.keyDown,
                         .leftMouseDown, .leftMouseUp,
                         .rightMouseDown, .rightMouseUp,
                         .otherMouseDown, .otherMouseUp]
            ) { [weak self] type, event in
                // Callback runs on the main thread (we installed on main run loop).
                // Return true to pass through, false to swallow. Side-effects OK here.
                guard let self = self else { return true }
                return self.handleEvent(type: type, event: event)
            }
            self.eventTap = tap
            Log.shared.line("Event tap: ✅ (Input Monitoring granted)")
        } catch {
            Log.shared.line("Event tap: ❌ \(error.localizedDescription)")
            Log.shared.line("Toggle OpenScribe ON under Privacy & Security → Input Monitoring, then quit and re-run.")
        }

        // ~30 Hz tracker catches window moves, scrolls, and focus changes
        // that don't generate keystrokes.
        tracker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updateOverlay(logOnMiss: false)
        }
        if let t = tracker { RunLoop.main.add(t, forMode: .common) }

        // Kick off model load in the background. UI reflects state via the menu bar.
        Task { await self.runner.loadIfNeeded() }
        startStatusPolling()
    }

    private func startStatusPolling() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task {
                let state = await self.runner.state
                await MainActor.run { self.reflectModelState(state) }
            }
        }
    }

    private func reflectModelState(_ state: ModelRunner.State) {
        guard let button = statusItem?.button else { return }
        switch state {
        case .idle:                      button.title = "✎ …"
        case .loading(let f):            button.title = "✎ \(Int(f * 100))%"
        case .ready:                     button.title = "✎"
        case .failed:                    button.title = "✎ ⚠︎"
        }
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
        // Pass our own synthesized typing straight through — don't re-process.
        if event.getIntegerValueField(.eventSourceUserData) == synthesizedMarker {
            return true
        }

        switch type {
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            // Tab/Esc are only ours when NO modifiers are held. Cmd+Tab is the app
            // switcher, Shift+Tab is outdent, Cmd+Esc force-quits — we must pass
            // those through unchanged.
            let modMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            let hasModifiers = !event.flags.intersection(modMask).isEmpty

            // Tab (48): commit just the next word from the current suggestion.
            if keyCode == 48 && !hasModifiers, let suggestion = currentSuggestion {
                let (chunk, rest) = nextChunk(of: suggestion)
                Log.shared.line("Tab commit chunk='\(chunk)'  remaining='\(rest)'")
                typeText(chunk)
                if rest.isEmpty {
                    dismissOverlay()
                } else {
                    currentSuggestion = rest
                    // Reposition overlay once the synthesized keystrokes have landed
                    // and AX reflects the new caret.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
                        self.updateOverlay(logOnMiss: false)
                    }
                }
                return false  // swallow Tab
            }

            // Escape (53): dismiss without committing. Plain Escape only.
            if keyCode == 53 && !hasModifiers, currentSuggestion != nil {
                Log.shared.line("Escape dismiss")
                dismissOverlay()
                return false
            }

            // Any other key: reset the current suggestion so the overlay regenerates
            // from scratch (rather than continuing to show a partially-consumed chunk
            // that no longer makes sense after new typing).
            currentSuggestion = nil
            DispatchQueue.main.async { self.updateOverlay(logOnMiss: true) }
            return true

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            mousePressed = true
            dismissOverlay()
            return true

        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            mousePressed = false
            DispatchQueue.main.async { self.updateOverlay(logOnMiss: false) }
            return true

        default:
            return true
        }
    }

    private func dismissOverlay() {
        overlay?.hide()
        currentSuggestion = nil
    }

    /// Splits off the next Tab-committable chunk from the front of `s`.
    /// Rules: any leading whitespace is attached to the following chunk; a word run
    /// (letters / digits / apostrophes) is one chunk; each punctuation mark is its own
    /// chunk. So `"lazy dog"` → `("lazy", " dog")` → `(" dog", "")`, and `"hi, world"`
    /// → `("hi", ", world")` → `(",", " world")` → `(" world", "")`.
    func nextChunk(of s: String) -> (chunk: String, rest: String) {
        let chars = Array(s)
        if chars.isEmpty { return ("", "") }

        var i = 0
        while i < chars.count && chars[i].isWhitespace { i += 1 }
        if i >= chars.count { return (String(chars), "") }

        let start = i
        let first = chars[i]
        if first.isLetter || first.isNumber {
            while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "'") {
                i += 1
            }
        } else {
            i += 1  // one punctuation mark
        }
        _ = start
        let chunk = String(chars[0..<i])
        let rest = String(chars[i...])
        return (chunk, rest)
    }

    /// Synthesizes `s` as Unicode keyboard events. Each character is posted tagged with
    /// `synthesizedMarker` so our own event tap knows to pass it through.
    private func typeText(_ s: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for char in s {
            var utf16 = Array(String(char).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                continue
            }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.setIntegerValueField(.eventSourceUserData, value: synthesizedMarker)
            up.setIntegerValueField(.eventSourceUserData, value: synthesizedMarker)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    /// Single source of truth for overlay state. Called from the event tap (on keystrokes
    /// and mouse-up) and from the tracker timer (for drift between events).
    private func updateOverlay(logOnMiss: Bool) {
        if mousePressed {
            dismissOverlay()
            return
        }
        guard let ctx = AXContext.read() else {
            if logOnMiss { Log.shared.line("ctx=nil (unsupported surface)") }
            dismissOverlay()
            return
        }

        // Reset backward-nav tracking when the focused app changes — a caret offset
        // from one app is meaningless in another.
        if ctx.bundleId != prevBundleId {
            prevCaretOffset = -1
            hiddenByBackwardNav = false
            prevBundleId = ctx.bundleId
        }

        // If the caret moved backward since the previous update, latch the overlay
        // hidden. It stays hidden until the caret advances forward again (via typing
        // or right/down arrow). This works in terminals too, where the value-length
        // check can't reliably detect "end of input."
        if prevCaretOffset >= 0 {
            if ctx.caretOffset < prevCaretOffset {
                hiddenByBackwardNav = true
            } else if ctx.caretOffset > prevCaretOffset {
                hiddenByBackwardNav = false
            }
        }
        prevCaretOffset = ctx.caretOffset

        if hiddenByBackwardNav {
            dismissOverlay()
            return
        }

        // Non-terminal end-of-text check: don't render over existing content.
        // Terminals are skipped because AX can't tell their user input apart from
        // TUI chrome (status bars, Claude Code widgets below the prompt).
        let isTerminal = AXContext.isTerminalApp(bundleId: ctx.bundleId)
        if !isTerminal && ctx.caretOffset < ctx.value.utf16.count {
            dismissOverlay()
            return
        }

        // If we're in the middle of consuming a previous suggestion word-by-word,
        // keep showing the remaining portion instead of fetching a new one.
        if let existing = currentSuggestion, !existing.isEmpty {
            overlay?.show(suggestion: existing, in: ctx)
            return
        }

        // Build a prompt context from the text before the caret.
        let head = ctx.value
        let contextForModel = String(head.suffix(400))

        // De-dupe: don't fire a new request for identical context.
        if contextForModel == lastRequestedContext { return }
        lastRequestedContext = contextForModel

        Task { [weak self] in
            guard let self = self else { return }
            let state = await self.runner.state
            guard case .ready = state else {
                // Briefly show that the model is still coming up.
                await MainActor.run {
                    self.overlay?.show(suggestion: self.placeholderSuggestion, in: ctx)
                    self.currentSuggestion = self.placeholderSuggestion
                }
                return
            }
            let suggestion = await self.runner.suggest(context: contextForModel)
            guard let s = suggestion, !s.isEmpty else {
                await MainActor.run { self.dismissOverlay() }
                return
            }
            // Re-check freshness: if the user has typed since, our suggestion is stale.
            await MainActor.run {
                if self.lastRequestedContext == contextForModel, let freshCtx = AXContext.read() {
                    self.overlay?.show(suggestion: s, in: freshCtx)
                    self.currentSuggestion = s
                }
            }
        }
    }

    private func rectFmt(_ r: CGRect) -> String {
        "(x=\(Int(r.minX)),y=\(Int(r.minY)),w=\(Int(r.width)),h=\(Int(r.height)))"
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "✎"
            button.toolTip = "OpenScribe"
        }
        let menu = NSMenu()
        let openLogItem = NSMenuItem(title: "Open log",
                                     action: #selector(openLog),
                                     keyEquivalent: "l")
        openLogItem.target = self
        menu.addItem(openLogItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit OpenScribe",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Log.shared.path))
    }

    private func showAccessibilityAlertAndQuit() {
        let alert = NSAlert()
        alert.messageText = "OpenScribe needs Accessibility permission"
        alert.informativeText = """
            To show suggestions in other apps, OpenScribe needs access to the \
            Accessibility API. Grant it in System Settings → Privacy & Security \
            → Accessibility, then relaunch OpenScribe.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")

        // LSUIElement apps don't auto-focus; nudge the alert to the front.
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
        NSApp.terminate(nil)
    }
}
