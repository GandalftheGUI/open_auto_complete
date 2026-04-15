import Cocoa

/// A transparent, click-through, always-on-top window that renders ghost text
/// sitting on the caret of the host app's focused text field.
final class Overlay {

    private let window: NSWindow
    private let textView: NSTextView

    init() {
        let rect = NSRect(x: 0, y: 0, width: 400, height: 20)
        let win = NSWindow(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        // Above .popUpMenu (101) so browser URL-suggestion dropdowns and similar
        // floating lists don't occlude our ghost text.
        win.level = NSWindow.Level(rawValue: 200)
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle,
                                  .fullScreenAuxiliary]
        win.hidesOnDeactivate = false

        let tv = NSTextView(frame: rect)
        tv.isEditable = false
        tv.isSelectable = false
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.heightTracksTextView = false

        win.contentView = tv

        self.window = win
        self.textView = tv
    }

    /// Render `suggestion` as ghost text positioned on the caret described by `ctx`.
    /// `firstLineHeadIndent` is set so line 1 starts at the caret, line 2+ wraps to
    /// the host field's left edge — preventing horizontal overflow.
    func show(suggestion: String, in ctx: CaretContext) {
        guard !suggestion.isEmpty else { hide(); return }

        // Convert AX screen coords (top-left origin) to Cocoa (bottom-left origin).
        // The overlay's top-left should align with the top-left of the caret's line.
        let screenHeight = primaryScreenHeight()

        // Text-container metrics. Use the host field's width as the line width so
        // NSTextView wraps exactly where the host would.
        let containerLeft = ctx.fieldFrame.minX
        let containerWidth = max(40, ctx.fieldFrame.maxX - containerLeft)

        // How far into the line the caret sits.
        let indent = max(0, ctx.caretRect.minX - containerLeft)

        // Build attributed string with dimmed color + first-line indent.
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = indent
        paragraph.lineBreakMode = .byWordWrapping

        let dimmed = ctx.textColor.withAlphaComponent(0.42)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: ctx.font,
            .foregroundColor: dimmed,
            .paragraphStyle: paragraph,
        ]
        let attributed = NSAttributedString(string: suggestion, attributes: attrs)
        textView.textStorage?.setAttributedString(attributed)

        // Fit the text to the container width and measure required height.
        if let container = textView.textContainer, let layout = textView.layoutManager {
            container.containerSize = NSSize(width: containerWidth, height: .greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            let height = max(ctx.caretRect.height, ceil(used.height))

            let topInScreenCoords = ctx.caretRect.minY
            let originYCocoa = screenHeight - topInScreenCoords - height

            let frame = NSRect(
                x: containerLeft,
                y: originYCocoa,
                width: containerWidth,
                height: height
            )
            window.setFrame(frame, display: false)
            textView.frame = NSRect(x: 0, y: 0, width: containerWidth, height: height)
        }

        if !window.isVisible {
            window.orderFrontRegardless()
        }
    }

    func hide() {
        if window.isVisible { window.orderOut(nil) }
    }

    private func primaryScreenHeight() -> CGFloat {
        // AX uses a global top-left-origin screen space rooted at the primary display.
        NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
    }
}
