import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var eventTap: EventTap?
    private var overlay: Overlay?
    private var tracker: Timer?
    private var mousePressed = false

    /// Hardcoded placeholder until M4 plugs in the LLM.
    private let placeholderSuggestion = "lazy dog jumps over the fence"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.shared.line("OpenScribe launched.  exec=\(Bundle.main.executablePath ?? "?")")
        Log.shared.line("Logging to: \(Log.shared.path)")

        installStatusItem()

        guard Permissions.ensureAccessibility() else {
            Log.shared.line("Accessibility: ❌ not granted. System Settings prompt should appear.")
            Log.shared.line("Toggle OpenScribe ON under Privacy & Security → Accessibility, then quit and re-run.")
            return
        }
        Log.shared.line("Accessibility: ✅")

        overlay = Overlay()

        do {
            let tap = try EventTap.installListenOnly(
                events: [.keyDown,
                         .leftMouseDown, .leftMouseUp,
                         .rightMouseDown, .rightMouseUp,
                         .otherMouseDown, .otherMouseUp]
            ) { [weak self] type, event in
                guard let self = self else { return }
                DispatchQueue.main.async { self.handleEvent(type: type, event: event) }
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
    }

    private func handleEvent(type: CGEventType, event: CGEvent) {
        switch type {
        case .keyDown:
            updateOverlay(logOnMiss: true)

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Hide immediately on mouse-down so drags don't leave a trail. The tracker
            // timer is suppressed while mousePressed == true.
            mousePressed = true
            overlay?.hide()

        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            mousePressed = false
            // Reappear immediately at the new caret location rather than waiting
            // for the next tracker tick.
            updateOverlay(logOnMiss: false)

        default:
            break
        }
    }

    /// Single source of truth for overlay state. Called from the event tap (on keystrokes
    /// and mouse-up) and from the tracker timer (for drift between events).
    private func updateOverlay(logOnMiss: Bool) {
        if mousePressed {
            overlay?.hide()
            return
        }
        guard let ctx = AXContext.read() else {
            if logOnMiss { Log.shared.line("ctx=nil (unsupported surface)") }
            overlay?.hide()
            return
        }
        overlay?.show(suggestion: placeholderSuggestion, in: ctx)
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
}
