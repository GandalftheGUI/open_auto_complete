import Cocoa

/// A plain in-app text box wired directly to `ModelRunner`, for interactively testing
/// suggestion quality without needing Accessibility/Input Monitoring permissions, AX
/// reads, or a real target app — we own the NSTextView directly, so caret position,
/// font, and content are all known exactly. This is the interactive counterpart to
/// `SuggestionProbe`'s canned-context batch mode: same generation pipeline, typed live.
///
/// Ghost text is rendered by inserting the suggestion directly into the text view with
/// a dimmed color, ahead of the real caret. Any real edit strips it first (via
/// `shouldChangeTextIn`) so it's never mistaken for committed text; Tab promotes it to
/// normal color and commits; Escape deletes it.
final class SandboxWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {

    static let shared = SandboxWindowController()

    private var textView: NSTextView!
    private var statusLabel: NSTextField!
    private var runner: ModelRunner?

    private var ghostRange: NSRange?
    private var isApplyingGhost = false
    private var pendingSuggestion: DispatchWorkItem?
    private var requestGen = 0
    private let debounceDelay: TimeInterval = 0.2

    private let normalAttrs: [NSAttributedString.Key: Any] = [
        .foregroundColor: NSColor.labelColor,
        .font: NSFont.systemFont(ofSize: 14),
    ]
    private let ghostAttrs: [NSAttributedString.Key: Any] = [
        .foregroundColor: NSColor.tertiaryLabelColor,
        .font: NSFont.systemFont(ofSize: 14),
    ]

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Suggestion Sandbox"
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        buildContent()
    }

    private func buildContent() {
        guard let window = window else { return }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
        content.autoresizingMask = [.width, .height]

        let hint = NSTextField(labelWithString: "Type at the end of the text. Tab accepts, Esc dismisses.")
        hint.frame = NSRect(x: 16, y: 332, width: 528, height: 16)
        hint.autoresizingMask = [.width, .minYMargin]
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.isBezeled = false
        hint.drawsBackground = false
        hint.isEditable = false
        content.addSubview(hint)

        let scrollView = NSScrollView(frame: NSRect(x: 16, y: 40, width: 528, height: 284))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 528, height: 284))
        tv.autoresizingMask = [.width, .height]
        tv.isRichText = false
        tv.font = NSFont.systemFont(ofSize: 14)
        tv.textColor = .labelColor
        tv.typingAttributes = normalAttrs
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.delegate = self
        scrollView.documentView = tv
        content.addSubview(scrollView)
        self.textView = tv

        let status = NSTextField(labelWithString: "")
        status.frame = NSRect(x: 16, y: 12, width: 528, height: 18)
        status.autoresizingMask = [.width, .maxYMargin]
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .tertiaryLabelColor
        status.isBezeled = false
        status.drawsBackground = false
        status.isEditable = false
        content.addSubview(status)
        self.statusLabel = status

        window.contentView = content
    }

    func show(runner: ModelRunner) {
        self.runner = runner
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if !isApplyingGhost, let range = ghostRange {
            removeGhost(range)
        }
        return true
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertTab(_:)), let range = ghostRange {
            acceptGhost(range)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), let range = ghostRange {
            removeGhost(range)
            return true
        }
        return false
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingGhost else { return }
        scheduleSuggestion()
    }

    // MARK: - Suggestion pipeline

    private func scheduleSuggestion() {
        pendingSuggestion?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fireSuggestion() }
        pendingSuggestion = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceDelay, execute: work)
    }

    private func fireSuggestion() {
        guard let runner = runner, let tv = textView else { return }
        let text = tv.string
        let caret = tv.selectedRange().location
        guard caret == (text as NSString).length else { return }
        let context = String(text.suffix(400))
        let meaningful = context.filter { !$0.isWhitespace }.count
        guard meaningful >= 3 else {
            statusLabel.stringValue = ""
            return
        }

        requestGen += 1
        let myGen = requestGen
        statusLabel.stringValue = "Thinking…"

        Task { [weak self] in
            guard let self = self else { return }
            let state = await runner.state
            guard case .ready = state else {
                await MainActor.run { self.statusLabel.stringValue = "Model not ready: \(state)" }
                return
            }
            let t0 = Date()
            let suggestion = await runner.suggest(context: context)
            let elapsed = Int(Date().timeIntervalSince(t0) * 1000)
            await MainActor.run {
                guard self.requestGen == myGen else { return }
                guard let raw = suggestion, !raw.isEmpty else {
                    self.statusLabel.stringValue = "(no suggestion, \(elapsed)ms)"
                    return
                }
                let stripped = AppDelegate.stripSuffixOverlap(suggestion: raw, against: context)
                guard !stripped.isEmpty else {
                    self.statusLabel.stringValue = "(empty after overlap strip, \(elapsed)ms)"
                    return
                }
                self.statusLabel.stringValue = "\"\(stripped)\"  — \(elapsed)ms"
                self.showGhost(stripped)
            }
        }
    }

    private func showGhost(_ suggestion: String) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let text = tv.string as NSString
        let caret = tv.selectedRange().location
        guard caret == text.length else { return }

        isApplyingGhost = true
        storage.insert(NSAttributedString(string: suggestion, attributes: ghostAttrs), at: caret)
        tv.setSelectedRange(NSRange(location: caret, length: 0))
        ghostRange = NSRange(location: caret, length: (suggestion as NSString).length)
        isApplyingGhost = false
    }

    private func acceptGhost(_ range: NSRange) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        isApplyingGhost = true
        storage.setAttributes(normalAttrs, range: range)
        tv.setSelectedRange(NSRange(location: range.location + range.length, length: 0))
        tv.typingAttributes = normalAttrs
        isApplyingGhost = false
        ghostRange = nil
        scheduleSuggestion()
    }

    private func removeGhost(_ range: NSRange) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        isApplyingGhost = true
        storage.deleteCharacters(in: range)
        tv.typingAttributes = normalAttrs
        isApplyingGhost = false
        ghostRange = nil
        statusLabel.stringValue = ""
    }
}
