import Cocoa

/// Minimal AppKit settings window. Two popups (model + accept key), a help note,
/// and a close button. All changes write through to `Settings.shared` immediately.
/// Model changes require a quit + relaunch (the model is loaded once at startup);
/// key changes take effect on the next keystroke.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    static let shared = SettingsWindowController()

    private var modelPopup: NSPopUpButton!
    private var keyPopup: NSPopUpButton!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenAutoComplete Settings"
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        buildContent()
    }

    private func buildContent() {
        guard let window = window else { return }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 240))

        // --- Model row ---
        let modelLabel = NSTextField(labelWithString: "Model:")
        modelLabel.frame = NSRect(x: 20, y: 184, width: 90, height: 20)
        modelLabel.alignment = .right
        content.addSubview(modelLabel)

        modelPopup = NSPopUpButton(frame: NSRect(x: 120, y: 180, width: 320, height: 28))
        for (i, model) in Settings.Catalog.models.enumerated() {
            modelPopup.addItem(withTitle: "\(model.label)  (\(model.approxSize))")
            if model.id == Settings.shared.modelId {
                modelPopup.selectItem(at: i)
            }
        }
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged(_:))
        content.addSubview(modelPopup)

        let modelHint = NSTextField(labelWithString: "First-time use of a model downloads its weights (~1–4 GB).")
        modelHint.frame = NSRect(x: 120, y: 158, width: 320, height: 16)
        modelHint.font = NSFont.systemFont(ofSize: 11)
        modelHint.textColor = .secondaryLabelColor
        modelHint.isBezeled = false
        modelHint.drawsBackground = false
        modelHint.isEditable = false
        content.addSubview(modelHint)

        // --- Accept key row ---
        let keyLabel = NSTextField(labelWithString: "Accept key:")
        keyLabel.frame = NSRect(x: 20, y: 116, width: 90, height: 20)
        keyLabel.alignment = .right
        content.addSubview(keyLabel)

        keyPopup = NSPopUpButton(frame: NSRect(x: 120, y: 112, width: 200, height: 28))
        for (i, key) in Settings.Catalog.acceptKeys.enumerated() {
            keyPopup.addItem(withTitle: key.label)
            if key.keyCode == Settings.shared.acceptKeyCode {
                keyPopup.selectItem(at: i)
            }
        }
        keyPopup.target = self
        keyPopup.action = #selector(keyChanged(_:))
        content.addSubview(keyPopup)

        let keyHint = NSTextField(labelWithString: "Press this key to commit the next word of the suggestion.")
        keyHint.frame = NSRect(x: 120, y: 90, width: 320, height: 16)
        keyHint.font = NSFont.systemFont(ofSize: 11)
        keyHint.textColor = .secondaryLabelColor
        keyHint.isBezeled = false
        keyHint.drawsBackground = false
        keyHint.isEditable = false
        content.addSubview(keyHint)

        // --- Restart note ---
        let note = NSTextField(labelWithString: "Model changes take effect after quitting and relaunching OpenAutoComplete.")
        note.frame = NSRect(x: 20, y: 30, width: 420, height: 32)
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.isBezeled = false
        note.drawsBackground = false
        note.isEditable = false
        content.addSubview(note)

        window.contentView = content
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        guard i >= 0, i < Settings.Catalog.models.count else { return }
        Settings.shared.modelId = Settings.Catalog.models[i].id
    }

    @objc private func keyChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        guard i >= 0, i < Settings.Catalog.acceptKeys.count else { return }
        Settings.shared.acceptKeyCode = Settings.Catalog.acceptKeys[i].keyCode
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
