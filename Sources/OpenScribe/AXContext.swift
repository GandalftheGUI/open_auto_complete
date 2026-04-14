import Cocoa
import ApplicationServices

/// A snapshot of the focused text field's state, in screen coordinates,
/// enriched with best-guess styling. Everything we need to draw the overlay.
struct CaretContext {
    let appName: String
    let bundleId: String
    let caretRect: CGRect       // screen coords, AX top-left origin
    let fieldFrame: CGRect      // screen coords, AX top-left origin
    let value: String
    let caretOffset: Int
    let font: NSFont
    let textColor: NSColor
}

enum AXContext {

    /// Reads the current focused field. Returns nil if no AX element is focused
    /// (e.g. Chromium address bar, Google Docs canvas, no focused app).
    static func read() -> CaretContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)

        guard let focusedAny = copy(appEl, kAXFocusedUIElementAttribute as CFString) else {
            return nil
        }
        let element = focusedAny as! AXUIElement

        // Selected range → caret offset.
        guard let rangeAny = copy(element, kAXSelectedTextRangeAttribute as CFString),
              let selRange = readRange(rangeAny) else {
            return nil
        }

        // Caret rect — ask for the character at (offset - 1), or offset 0 if at start.
        let probeLoc = max(0, selRange.location - 1)
        guard let caretRect = boundsForRange(element, location: probeLoc, length: 1) else {
            return nil
        }

        // Field frame.
        guard let fieldFrame = frameOf(element) else {
            return nil
        }

        // Value (may be missing on some apps like iTerm in some modes; fall back to empty).
        let value = (copy(element, kAXValueAttribute as CFString) as? String) ?? ""

        // Font + color — attempt AX attributed string, fall back to system defaults.
        let bundleId = app.bundleIdentifier ?? ""
        let (font, color) = styleNearCaret(element, before: selRange.location, bundleId: bundleId)

        return CaretContext(
            appName: app.localizedName ?? "?",
            bundleId: app.bundleIdentifier ?? "?",
            caretRect: caretRect,
            fieldFrame: fieldFrame,
            value: value,
            caretOffset: selRange.location,
            font: font,
            textColor: color
        )
    }

    // MARK: - AX helpers

    private static func copy(_ el: AXUIElement, _ attr: CFString) -> AnyObject? {
        var out: AnyObject?
        return AXUIElementCopyAttributeValue(el, attr, &out) == .success ? out : nil
    }

    private static func copyParam(_ el: AXUIElement, _ attr: CFString, _ param: AnyObject) -> AnyObject? {
        var out: AnyObject?
        return AXUIElementCopyParameterizedAttributeValue(el, attr, param, &out) == .success ? out : nil
    }

    private static func readRange(_ v: AnyObject) -> CFRange? {
        var r = CFRange(location: 0, length: 0)
        return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
    }

    private static func boundsForRange(_ el: AXUIElement, location: Int, length: Int) -> CGRect? {
        var r = CFRange(location: location, length: length)
        guard let param = AXValueCreate(.cfRange, &r) else { return nil }
        guard let out = copyParam(el, kAXBoundsForRangeParameterizedAttribute as CFString, param) else {
            return nil
        }
        var rect = CGRect.zero
        return AXValueGetValue(out as! AXValue, .cgRect, &rect) ? rect : nil
    }

    private static func frameOf(_ el: AXUIElement) -> CGRect? {
        guard let posAny = copy(el, kAXPositionAttribute as CFString),
              let sizeAny = copy(el, kAXSizeAttribute as CFString) else {
            return nil
        }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(posAny as! AXValue, .cgPoint, &p),
              AXValueGetValue(sizeAny as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// Fetch the AX attributed string for the character before the caret, and derive
    /// a Cocoa font + color. Precedence: user config → AX attributed string → built-in
    /// host-appropriate default (monospace for known terminal apps).
    private static func styleNearCaret(_ el: AXUIElement, before caretLoc: Int, bundleId: String) -> (NSFont, NSColor) {
        let fallbackColor = NSColor.labelColor

        // 1. Highest priority: explicit user override from config.json.
        if let override = Config.shared.fontOverride(forBundle: bundleId) {
            return (override, fallbackColor)
        }

        // Built-in per-app default, used when AX is silent.
        func hostFallbackFont(size: CGFloat) -> NSFont {
            if let (name, defaultSize) = terminalDefault(bundleId: bundleId) {
                let s = size > 0 ? size : defaultSize
                return NSFont(name: name, size: s)
                    ?? NSFont.monospacedSystemFont(ofSize: s, weight: .regular)
            }
            return NSFont.systemFont(ofSize: size > 0 ? size : 14)
        }

        guard caretLoc > 0 else { return (hostFallbackFont(size: -1), fallbackColor) }

        var r = CFRange(location: caretLoc - 1, length: 1)
        guard let param = AXValueCreate(.cfRange, &r),
              let any = copyParam(el, kAXAttributedStringForRangeParameterizedAttribute as CFString, param),
              let attr = any as? NSAttributedString, attr.length > 0 else {
            return (hostFallbackFont(size: defaultSize), fallbackColor)
        }

        let attrs = attr.attributes(at: 0, effectiveRange: nil)

        // Font: prefer AX font dict; fall back to Cocoa .font; then host-appropriate default.
        // Even when AX gives us only a size (e.g. Chromium), use that size with the fallback family.
        var font: NSFont
        if let axFont = attrs[NSAttributedString.Key("AXFont")] as? [String: Any] {
            let size = (axFont["AXFontSize"] as? Double) ?? defaultSize
            if let name = axFont["AXFontName"] as? String, !name.isEmpty,
               let f = NSFont(name: name, size: size) {
                font = f
            } else if let family = axFont["AXFontFamily"] as? String, !family.isEmpty,
                      let f = NSFont(name: family, size: size) {
                font = f
            } else {
                font = hostFallbackFont(size: size)
            }
        } else if let cocoaFont = attrs[.font] as? NSFont {
            font = cocoaFont
        } else {
            font = hostFallbackFont(size: defaultSize)
        }

        var color = fallbackColor
        if let cg = attrs[NSAttributedString.Key("AXForegroundColor")] {
            let cgColor = cg as! CGColor
            if let ns = NSColor(cgColor: cgColor) { color = ns }
        } else if let cocoaColor = attrs[.foregroundColor] as? NSColor {
            color = cocoaColor
        }

        return (font, color)
    }

    /// Bundle IDs of terminal emulators we know use monospace by default.
    /// When AX doesn't expose a font name for these apps, we fall back to Menlo/SF Mono
    /// instead of the proportional system font.
    private static func isTerminal(bundleId: String) -> Bool {
        let ids: Set<String> = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.mitchellh.ghostty",
            "dev.warp.Warp-Stable",
            "net.kovidgoyal.kitty",
            "io.alacritty",
            "com.github.wez.wezterm",
        ]
        return ids.contains(bundleId)
    }
}
