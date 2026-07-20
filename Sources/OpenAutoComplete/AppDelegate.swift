import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var eventTap: EventTap?
    private var overlay: Overlay?
    private var tracker: Timer?
    private var mousePressed = false

    private let runner = ModelRunner()
    private let typedBuffer = KeystrokeBuffer()

    // Generation counter: each time we actually SEND a request to the model, we bump
    // this and capture the current value. When a response arrives, we check that the
    // captured value still matches — if not, a newer request has superseded us and
    // we discard the stale result. This replaces a prior string-equality staleness
    // check that was rejecting valid responses when AX returned subtle variations
    // (pixel-shift caret rects, DOM-noise in Chromium) between request and reply.
    private var requestGen: Int = 0

    // What we last sent to the model, used to skip identical re-requests when the
    // user is idle (tracker ticks at 30 Hz but context doesn't change).
    private var lastSentContext: String = ""

    // Debounce handle — replaces any pending request when a new one arrives. With
    // mid-decode cancellation at the ModelRunner level (each new request bumps a
    // monotonic id; older in-flight generations check it between tokens and bail),
    // we can keep this tiny. Purpose of the debounce is only to collapse same-tick
    // events like auto-repeat.
    private var pendingSuggestion: DispatchWorkItem?
    private let debounceDelay: TimeInterval = 0.02

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
        Log.shared.line("OpenAutoComplete launched.  exec=\(Bundle.main.executablePath ?? "?")")
        Log.shared.line("Logging to: \(Log.shared.path)")

        installStatusItem()

        // Kick off model load in the background regardless of permissions below —
        // the Suggestion Sandbox and headless --probe mode only need the model, not
        // AX/Input Monitoring, so they work even when the system-wide overlay can't.
        Task { await self.runner.loadIfNeeded() }
        startStatusPolling()

        // The system-wide overlay (AX reads + event tap) is the only thing that
        // actually needs Accessibility/Input Monitoring. Every rebuild re-signs the
        // app with a new ad-hoc signature, which invalidates those TCC grants each
        // time — quitting here on a missing grant turned every rebuild into a
        // permission-regrant dance even when only the Sandbox was being used. Now a
        // missing grant just disables the overlay for this launch; the menu bar,
        // model, and Sandbox all still work.
        guard Permissions.ensureAccessibility() else {
            Log.shared.line("Accessibility: ❌ not granted — system-wide overlay disabled for this launch (Sandbox still works). Grant in Privacy & Security → Accessibility to enable it.")
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
            Log.shared.line("Toggle OpenAutoComplete ON under Privacy & Security → Input Monitoring, then quit and re-run.")
        }

        // ~30 Hz tracker catches window moves, scrolls, and focus changes. It only
        // reanchors the existing overlay to the current caret — it deliberately does
        // NOT trigger new model requests. Firing requests is keystroke-driven only.
        tracker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.trackerTick()
        }
        if let t = tracker { RunLoop.main.add(t, forMode: .common) }

        // OCR screen-context: capture on focus change. Best-effort; if Screen
        // Recording isn't granted we'll simply never have OCR data and fall back to
        // AX-only behaviour.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        // Capture for the currently-frontmost app at startup, too.
        Task { await OCRCache.shared.startCapture() }
    }

    @objc private func appActivated(_ note: Notification) {
        typedBuffer.invalidate()  // new app = new field, reseed from AX on next read
        Task { await OCRCache.shared.startCapture() }
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

    /// Lightweight re-render of the existing suggestion at the current caret. Called
    /// by the tracker at 30 Hz; never fires model requests, never touches the debounce
    /// timer. The old code conflated these, so the tracker kept cancelling the
    /// debounce every 33 ms and model requests never had a chance to fire.
    private func trackerTick() {
        if mousePressed {
            overlay?.hide()
            return
        }
        guard let existing = currentSuggestion, !existing.isEmpty else {
            // No suggestion to re-anchor; nothing to do.
            return
        }
        guard let ctx = AXContext.read() else {
            overlay?.hide()
            return
        }
        overlay?.show(suggestion: existing, in: ctx)
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

            // For buffer tracking and match-advance, Shift alone doesn't make a
            // keystroke untrackable — `character(from:)` already resolves it to the
            // correct literal (capital letter, shifted punctuation), so plain Shift
            // combos are just normal typing. Only Cmd/Ctrl/Alt produce effects we
            // can't mirror (shortcuts, app-defined bindings), so only those should
            // invalidate the optimistic buffer or force a divergence re-fire.
            let untrackableModMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
            let hasUntrackableModifiers = !event.flags.intersection(untrackableModMask).isEmpty

            // Hybrid buffer maintenance: mirror the host's text field optimistically
            // so we can build prompt context without waiting for AX to catch up.
            // Anything we can't cheaply keep in sync (cursor jumps, modifier combos,
            // keys that aren't literal insertions) invalidates the buffer and we
            // fall back to AX on the next read.
            let currentBundle = AXContext.read()?.bundleId ?? ""
            switch keyCode {
            case 123, 124, 125, 126,     // arrow keys
                 115, 119, 116, 121,     // home/end/pgup/pgdn
                 117:                    // forward-delete
                typedBuffer.invalidate()
            case 51:  // backspace
                if !hasUntrackableModifiers {
                    typedBuffer.backspace(for: currentBundle)
                } else {
                    typedBuffer.invalidate()  // alt+delete, cmd+delete are word/line ops
                }
            default:
                if hasUntrackableModifiers {
                    // Cmd+V paste, Cmd+Z undo, etc — we can't track the effect.
                    typedBuffer.invalidate()
                } else if let ch = Self.character(from: event) {
                    typedBuffer.appendCharacter(ch, for: currentBundle)
                } else {
                    Log.shared.line("buffer: character decode failed for keyCode=\(keyCode)")
                }
            }

            // Configurable accept key (default Tab = 48) — user-overridable in settings.
            let acceptKey = Settings.shared.acceptKeyCode
            if keyCode == acceptKey && !hasModifiers, let suggestion = currentSuggestion {
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

            // Match-advance: if the user types a character that matches the next
            // character of the current suggestion, trim the suggestion by that
            // character and keep the overlay visible. This is the 80% case during
            // a user "following the prediction" run and saves a full model call
            // per keystroke.
            let typedChar: Character? = Self.character(from: event)
            if let existing = currentSuggestion,
               !existing.isEmpty,
               !hasUntrackableModifiers,
               let first = typedChar,
               let suggestionFirst = existing.first,
               first == suggestionFirst {
                let trimmed = String(existing.dropFirst())
                Log.shared.line("match-advance: consumed '\(first)', remaining='\(trimmed)'")
                if trimmed.isEmpty {
                    dismissOverlay()
                } else {
                    currentSuggestion = trimmed
                    // Re-render on next runloop tick, after host app processes the
                    // keystroke so AX caret has advanced.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                        self.trackerTick()
                    }
                }
                return true  // don't swallow, let the host app type the char normally
            }

            // Otherwise: user diverged from the prediction. Reset and ask for a fresh
            // suggestion based on the new context.
            if currentSuggestion != nil {
                Log.shared.line("divergence: typed='\(typedChar.map(String.init) ?? "?")', clearing suggestion and re-firing")
            }
            // Hide the visible overlay immediately so the old (now-irrelevant)
            // suggestion doesn't linger next to the caret while we're asking the
            // model for a new one.
            dismissOverlay()
            hiddenByBackwardNav = false
            lastSentContext = ""
            DispatchQueue.main.async { self.updateOverlay(logOnMiss: true) }
            return true

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            mousePressed = true
            // Click likely repositions the caret; buffer's "caret at end" invariant
            // may no longer hold.
            typedBuffer.invalidate()
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

    /// Decodes the single Unicode character emitted by a CGEvent.keyDown. Returns nil
    /// for events that don't produce text (arrow keys, F-keys, modifier-only presses).
    /// Uses a single pre-allocated buffer — the two-call "query length first" pattern
    /// silently fails for some events because `actualStringLength` isn't reliably
    /// populated when `unicodeString` is nil.
    static func character(from event: CGEvent) -> Character? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { return nil }
        let s = String(utf16CodeUnits: buffer, count: length)
        guard s.count == 1 else { return nil }
        return s.first
    }

    /// If the suggestion begins with characters that the user has already typed at
    /// the tail of `context`, strip that overlap. Fixes subword-token misalignment:
    /// model sees "ho" and wants to emit "hopes", but its tokenizer splits "hopes"
    /// as ["h", "opes"], so its generated continuation is "opes" — concatenated
    /// gives "hoopes". We detect the overlap ("o" is both the last char of context
    /// and the first char of suggestion) and strip it.
    static func stripSuffixOverlap(suggestion: String, against context: String) -> String {
        guard !suggestion.isEmpty, !context.isEmpty else { return suggestion }
        // Cap the overlap search at 20 chars — overlaps above that aren't realistic
        // and checking more is wasted work.
        let maxCheck = min(suggestion.count, context.count, 20)
        for overlap in stride(from: maxCheck, through: 1, by: -1) {
            let contextSuffix = context.suffix(overlap)
            let suggestionPrefix = suggestion.prefix(overlap)
            if contextSuffix == suggestionPrefix {
                return String(suggestion.dropFirst(overlap))
            }
        }
        return suggestion
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

        let first = chars[i]
        if first.isLetter || first.isNumber {
            while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "'") {
                i += 1
            }
        } else {
            i += 1  // one punctuation mark
        }
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
        // Mid-commit: we have a partially-consumed suggestion. Keep showing it no
        // matter what — the user is Tab-ing through it and any transient AX weirdness
        // (during synthesized keystroke delivery, or mid-window-focus-change) must not
        // trigger a fresh model request. Cleared only by explicit user action
        // (non-Tab key, Escape, mouse click, backward-nav, app switch).
        if let existing = currentSuggestion, !existing.isEmpty, !mousePressed {
            if let ctx = AXContext.read() {
                overlay?.show(suggestion: existing, in: ctx)
            } else {
                overlay?.hide()
            }
            return
        }

        if mousePressed {
            // Just hide the window; don't invalidate suggestion (drag might be a
            // window move, not a caret reposition).
            overlay?.hide()
            return
        }
        guard let ctx = AXContext.read() else {
            if logOnMiss { Log.shared.line("ctx=nil (unsupported surface)") }
            // Transient AX failure — hide but don't clobber state.
            overlay?.hide()
            return
        }

        // Reset backward-nav tracking when the focused app changes — a caret offset
        // from one app is meaningless in another. Also fully reset state, including
        // clearing the latched `hiddenByBackwardNav` flag, so app switches don't
        // inherit suppression state from a prior session.
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
            if logOnMiss { Log.shared.line("skip: hiddenByBackwardNav (prev=\(prevCaretOffset), cur=\(ctx.caretOffset))") }
            dismissOverlay()
            return
        }

        // Non-terminal end-of-text check: don't render over existing content.
        // Terminals are skipped because AX can't tell their user input apart from
        // TUI chrome (status bars, Claude Code widgets below the prompt).
        // We tolerate a small gap (≤8 chars) between caret offset and value length
        // because fast typing frequently outruns AX's internal state update — AX
        // reports the NEW value but the OLD caret offset briefly.
        let isTerminal = AXContext.isTerminalApp(bundleId: ctx.bundleId)
        let gap = ctx.value.utf16.count - ctx.caretOffset
        if !isTerminal && gap > 8 {
            if logOnMiss { Log.shared.line("skip: caret mid-text (offset=\(ctx.caretOffset), len=\(ctx.value.utf16.count))") }
            // Hide the overlay but don't dismiss pipeline state — the user may just
            // be typing faster than AX can update its caret offset. Leaving
            // `currentSuggestion` alone lets a newer in-flight request still land.
            overlay?.hide()
            return
        }

        // (The currentSuggestion early-return lives at the top of this function — we
        // only reach here when currentSuggestion is nil, i.e. we need to fetch fresh.)

        // Reconcile our optimistic buffer with AX's ground truth. Buffer wins only
        // when AX is lagging (we've extended a known prefix); AX wins on any other
        // discrepancy (paste, autocorrect, something we missed).
        let caretAtEnd = ctx.caretOffset == ctx.value.utf16.count
        typedBuffer.reconcile(axValue: ctx.value, axCaretAtEnd: caretAtEnd, bundleId: ctx.bundleId)

        // Build a prompt context from the text before the caret. Prefer our buffer
        // (instant) over AX's value (can lag by 5-15 ms after a keystroke).
        let sourceText = typedBuffer.currentValue(for: ctx.bundleId) ?? ctx.value
        let contextForModel = String(sourceText.suffix(400))

        // Skip: too little signal to bother the model with. Covers empty fields,
        // pure-whitespace AX readouts from TUI chrome, and focus on system widgets.
        let meaningful = contextForModel.filter { !$0.isWhitespace }.count
        guard meaningful >= 10 else {
            if logOnMiss { Log.shared.line("skip: too little context (meaningful=\(meaningful))") }
            return
        }

        // Skip TUI chrome. In non-terminal apps, ANY box-drawing char means the AX
        // readout is definitely wrong (real prose never contains ─ or ┌). In
        // terminals, we allow a modest amount (to keep Claude-Code-with-typing working)
        // but refuse when the context is mostly chrome — otherwise we watched Gemma
        // hang on a pure-chrome Claude Code status line and lock up the runner.
        let boxDrawCount = contextForModel.unicodeScalars.filter { (0x2500...0x257F).contains($0.value) }.count
        let isTerminalApp = AXContext.isTerminalApp(bundleId: ctx.bundleId)
        if isTerminalApp {
            // >20% of chars being chrome → skip.
            if Double(boxDrawCount) / Double(max(contextForModel.count, 1)) > 0.2 { return }
        } else {
            if boxDrawCount > 0 { return }
        }

        // Skip self-log pollution: if the user opens openautocomplete.log in an editor and
        // focuses that window, AX feeds our own log lines back as "context" and we
        // end up asking the model to autocomplete its own output — nonsense, and the
        // generated output grows the log, which compounds next tick.
        let logSignatures = ["LLM  ←", "LLM  →", "Tab commit chunk=", "OpenAutoComplete launched"]
        for sig in logSignatures where contextForModel.contains(sig) {
            return
        }

        // Debounce: bursts of keystrokes collapse into a single request after the user
        // pauses for `debounceDelay`. We capture `bundleId` NOW (at context-capture
        // time) and pass it through — if focus changes during the debounce or during
        // generation, we'll detect it by comparing this captured value against the
        // freshly-read bundleId at render time.
        let capturedBundleId = ctx.bundleId
        Log.shared.line("debounce: scheduling for context(\(contextForModel.count) chars)")
        pendingSuggestion?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            Log.shared.line("debounce: firing")
            self.fireSuggestion(contextForModel: contextForModel, bundleId: capturedBundleId)
        }
        pendingSuggestion = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceDelay, execute: work)
    }

    private func fireSuggestion(contextForModel: String, bundleId sourceBundleId: String) {
        // Dedupe identical requests (tracker ticks on idle can fire repeated work items).
        if contextForModel == lastSentContext {
            Log.shared.line("fire skip: dedupe (context unchanged since last send)")
            return
        }
        lastSentContext = contextForModel

        requestGen += 1
        let myGen = requestGen

        Task { [weak self] in
            guard let self = self else { return }
            let state = await self.runner.state
            guard case .ready = state else {
                await MainActor.run {
                    if let ctx = AXContext.read() {
                        self.overlay?.show(suggestion: self.placeholderSuggestion, in: ctx)
                        self.currentSuggestion = self.placeholderSuggestion
                    }
                }
                return
            }

            // Optionally augment context with OCR tail when AX text is too short to
            // be useful (e.g. Reddit nested contenteditable returns minimal value).
            var promptContext = contextForModel
            if promptContext.count < 20,
               let cap = await OCRCache.shared.current(for: sourceBundleId) {
                let ocrTail = String(cap.joinedText.suffix(500))
                promptContext = "Nearby text on screen:\n\(ocrTail)\n\nUser is typing:\n\(contextForModel)"
                Log.shared.line("fire: augmenting short AX context (\(contextForModel.count) chars) with OCR (\(ocrTail.count) chars)")
            }

            let suggestion = await self.runner.suggest(context: promptContext)
            guard let raw = suggestion, !raw.isEmpty else {
                await MainActor.run { self.dismissOverlay() }
                return
            }
            let s = Self.stripSuffixOverlap(suggestion: raw, against: contextForModel)
            let ocrAnchor = await OCRCache.shared.findAnchor(
                typedTail: String(contextForModel.suffix(40)),
                for: sourceBundleId,
                within: AXContext.read()?.fieldFrame
            )

            await MainActor.run {
                // Only show if a newer request hasn't been sent since we started.
                guard self.requestGen == myGen else {
                    Log.shared.line("overlay skip: superseded by newer request")
                    return
                }
                guard let freshCtx = AXContext.read() else {
                    Log.shared.line("overlay skip: AX ctx nil at render time (app=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"))")
                    return
                }
                guard freshCtx.bundleId == sourceBundleId else {
                    Log.shared.line("overlay skip: focus changed during gen (\(sourceBundleId) → \(freshCtx.bundleId))")
                    return
                }

                // Decide effective caret: if AX's caret is clearly bogus (outside
                // the field) AND OCR found our typed text somewhere on screen,
                // anchor the overlay at the right edge of that OCR line.
                let axCaretInsideField = freshCtx.fieldFrame.contains(freshCtx.caretRect.origin)
                let effectiveCtx: CaretContext
                if !axCaretInsideField, let anchor = ocrAnchor {
                    Log.shared.line("overlay: using OCR anchor (AX caret outside field)  anchor=(x=\(Int(anchor.bounds.maxX)),y=\(Int(anchor.bounds.minY)))")
                    effectiveCtx = CaretContext(
                        appName: freshCtx.appName,
                        bundleId: freshCtx.bundleId,
                        caretRect: CGRect(
                            x: anchor.bounds.maxX,
                            y: anchor.bounds.minY,
                            width: 2,
                            height: anchor.bounds.height
                        ),
                        fieldFrame: freshCtx.fieldFrame,
                        value: freshCtx.value,
                        caretOffset: freshCtx.caretOffset,
                        font: freshCtx.font,
                        textColor: freshCtx.textColor
                    )
                } else {
                    // Off-screen guard only when we're using AX's caret directly.
                    let caretPoint = freshCtx.caretRect.origin
                    let onScreen = NSScreen.screens.contains { screen in
                        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                        let cocoaY = primaryHeight - caretPoint.y
                        return screen.frame.contains(CGPoint(x: caretPoint.x, y: cocoaY))
                    }
                    if !onScreen {
                        Log.shared.line("overlay skip: caret off-screen and no OCR anchor  caret=(\(Int(caretPoint.x)),\(Int(caretPoint.y)))")
                        return
                    }
                    effectiveCtx = freshCtx
                }

                Log.shared.line("overlay show: app=\(effectiveCtx.bundleId) caret=(\(Int(effectiveCtx.caretRect.minX)),\(Int(effectiveCtx.caretRect.minY))) suggestion=\"\(s)\"")
                self.overlay?.show(suggestion: s, in: effectiveCtx)
                self.currentSuggestion = s
            }
        }
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "✎"
            button.toolTip = "OpenAutoComplete"
        }
        let menu = NSMenu()

        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let openLogItem = NSMenuItem(title: "Open log",
                                     action: #selector(openLog),
                                     keyEquivalent: "l")
        openLogItem.target = self
        menu.addItem(openLogItem)

        let testOCRItem = NSMenuItem(title: "Test screen OCR",
                                     action: #selector(testScreenOCR),
                                     keyEquivalent: "")
        testOCRItem.target = self
        menu.addItem(testOCRItem)

        let sandboxItem = NSMenuItem(title: "Suggestion Sandbox…",
                                     action: #selector(openSandbox),
                                     keyEquivalent: "")
        sandboxItem.target = self
        menu.addItem(sandboxItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit OpenAutoComplete",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func openSandbox() {
        SandboxWindowController.shared.show(runner: runner)
    }

    @objc private func testScreenOCR() {
        guard Permissions.ensureScreenRecording() else {
            Log.shared.line("OCR test: Screen Recording not granted (toggle in System Settings, then quit + re-run)")
            return
        }
        Log.shared.line("OCR test: starting capture of focused window")
        Task {
            guard let cap = await ScreenContext.captureFocusedWindow() else {
                Log.shared.line("OCR test: capture failed")
                return
            }
            let preview = String(cap.joinedText.prefix(400)).replacingOccurrences(of: "\n", with: "\\n")
            Log.shared.line("OCR test: \(cap.lines.count) lines  preview \"\(preview)\"")
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Log.shared.path))
    }

}
