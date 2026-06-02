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
        // Caret height lets us derive a sensible point size even when the host app
        // (most notably terminals) refuses to expose font info.
        let bundleId = app.bundleIdentifier ?? ""
        let (font, color) = styleNearCaret(
            element,
            before: selRange.location,
            bundleId: bundleId,
            caretHeight: caretRect.height
        )

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
    /// `caretHeight` is the pixel height of the caret rect — used to derive a point
    /// size when AX doesn't hand us one directly.
    private static func styleNearCaret(_ el: AXUIElement, before caretLoc: Int, bundleId: String, caretHeight: CGFloat) -> (NSFont, NSColor) {
        let fallbackColor = NSColor.labelColor

        // 1. Highest priority: explicit user override from config.json.
        if let override = Config.shared.fontOverride(forBundle: bundleId) {
            return (override, fallbackColor)
        }

        // Caret-height → point size. Terminals typically add extra leading on top of
        // the glyph cell, so the ratio of caret height to point size tends to be
        // ~1.5 (e.g. Menlo 11pt in iTerm2 reports a ~17pt caret rect). Clamped to a
        // sane range so a bogus AX reading can't produce a 3pt or 60pt overlay.
        let derivedSize: CGFloat = {
            guard caretHeight > 0 else { return 0 }
            return min(max(caretHeight / 1.5, 9), 32)
        }()

        // Built-in per-app default, used when AX is silent on the font name.
        // Prefers the size derived from the caret height over any hardcoded default,
        // so font size tracks dynamic resizing (e.g. terminal ⌘+/⌘-).
        func hostFallbackFont(explicitSize: CGFloat) -> NSFont {
            let size: CGFloat
            if explicitSize > 0 {
                size = explicitSize
            } else if derivedSize > 0 {
                size = derivedSize
            } else if let (_, defaultSize) = terminalDefault(bundleId: bundleId) {
                size = defaultSize
            } else {
                size = 14
            }

            if let (name, _) = terminalDefault(bundleId: bundleId) {
                return NSFont(name: name, size: size)
                    ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            }
            return NSFont.systemFont(ofSize: size)
        }

        guard caretLoc > 0 else { return (hostFallbackFont(explicitSize: -1), fallbackColor) }

        var r = CFRange(location: caretLoc - 1, length: 1)
        guard let param = AXValueCreate(.cfRange, &r),
              let any = copyParam(el, kAXAttributedStringForRangeParameterizedAttribute as CFString, param),
              let attr = any as? NSAttributedString, attr.length > 0 else {
            return (hostFallbackFont(explicitSize: -1), fallbackColor)
        }

        let attrs = attr.attributes(at: 0, effectiveRange: nil)

        // Font: prefer AX font dict; fall back to Cocoa .font; then host-appropriate default.
        // Even when AX gives us only a size (e.g. Chromium), use that size with the fallback family.
        var font: NSFont
        if let axFont = attrs[NSAttributedString.Key("AXFont")] as? [String: Any] {
            let size = (axFont["AXFontSize"] as? Double) ?? 14
            if let name = axFont["AXFontName"] as? String, !name.isEmpty,
               let f = NSFont(name: name, size: size) {
                font = f
            } else if let family = axFont["AXFontFamily"] as? String, !family.isEmpty,
                      let f = NSFont(name: family, size: size) {
                font = f
            } else {
                font = hostFallbackFont(explicitSize: size)
            }
        } else if let cocoaFont = attrs[.font] as? NSFont {
            font = cocoaFont
        } else {
            font = hostFallbackFont(explicitSize: -1)
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

    /// True if the bundle ID belongs to a terminal emulator we know about.
    /// Callers use this to relax end-of-text checks, since terminals expose their
    /// whole visible buffer as one value and we can't tell the user's current input
    /// apart from TUI chrome below it.
    static func isTerminalApp(bundleId: String) -> Bool {
        terminalDefault(bundleId: bundleId) != nil
    }

    /// Default font + size per terminal, used only when AX doesn't expose a font
    /// and the user hasn't provided a config override. Match each terminal's
    /// out-of-box default so it "just works" for anyone on stock settings.
    private static func terminalDefault(bundleId: String) -> (String, CGFloat)? {
        switch bundleId {
        case "com.googlecode.iterm2":   return ("Menlo",   11)
        case "com.apple.Terminal":      return ("SFMono-Regular", 11)
        case "com.mitchellh.ghostty":   return ("Menlo",   13)
        case "dev.warp.Warp-Stable":    return ("Hack",    13)
        case "net.kovidgoyal.kitty",
             "io.alacritty",
             "com.github.wez.wezterm":  return ("Menlo",   12)
        default:                        return nil
        }
    }
}
