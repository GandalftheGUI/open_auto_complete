import Cocoa
import ApplicationServices

// MARK: - Logging

let logURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("axprobe.log")
let logHandle: FileHandle = {
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    return try! FileHandle(forWritingTo: logURL)
}()

func log(_ s: String) {
    print(s)
    fflush(stdout)
    if let data = (s + "\n").data(using: .utf8) {
        logHandle.write(data)
    }
}

// MARK: - Permission

func ensureAccessibility() {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let opts = [key: true] as CFDictionary
    if !AXIsProcessTrustedWithOptions(opts) {
        FileHandle.standardError.write(Data("""
        ⚠️  Accessibility permission required for this binary.
            Open System Settings → Privacy & Security → Accessibility,
            confirm AXProbe is enabled, then re-run.

        """.utf8))
        exit(1)
    }
}

// MARK: - AX helpers

var lastAXError: AXError = .success

func axCopy(_ element: AXUIElement, _ attr: String) -> AnyObject? {
    var result: AnyObject?
    let err = AXUIElementCopyAttributeValue(element, attr as CFString, &result)
    lastAXError = err
    return err == .success ? result : nil
}

func axCopyParam(_ element: AXUIElement, _ attr: String, _ param: AnyObject) -> AnyObject? {
    var result: AnyObject?
    let err = AXUIElementCopyParameterizedAttributeValue(element, attr as CFString, param, &result)
    lastAXError = err
    return err == .success ? result : nil
}

func errName(_ e: AXError) -> String {
    switch e {
    case .success:               return "success"
    case .failure:               return "failure"
    case .illegalArgument:       return "illegalArgument"
    case .invalidUIElement:      return "invalidUIElement"
    case .invalidUIElementObserver: return "invalidUIElementObserver"
    case .cannotComplete:        return "cannotComplete"
    case .attributeUnsupported:  return "attributeUnsupported"
    case .actionUnsupported:     return "actionUnsupported"
    case .notificationUnsupported: return "notificationUnsupported"
    case .notImplemented:        return "notImplemented"
    case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
    case .notificationNotRegistered: return "notificationNotRegistered"
    case .apiDisabled:           return "apiDisabled (Accessibility OFF for this binary)"
    case .noValue:               return "noValue"
    case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
    case .notEnoughPrecision:    return "notEnoughPrecision"
    @unknown default:            return "unknown(\(e.rawValue))"
    }
}

func cgPoint(from value: AnyObject?) -> CGPoint? {
    guard let value = value else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue(value as! AXValue, .cgPoint, &p) ? p : nil
}

func cgSize(from value: AnyObject?) -> CGSize? {
    guard let value = value else { return nil }
    var s = CGSize.zero
    return AXValueGetValue(value as! AXValue, .cgSize, &s) ? s : nil
}

func cgRect(from value: AnyObject?) -> CGRect? {
    guard let value = value else { return nil }
    var r = CGRect.zero
    return AXValueGetValue(value as! AXValue, .cgRect, &r) ? r : nil
}

func cfRange(from value: AnyObject?) -> CFRange? {
    guard let value = value else { return nil }
    var r = CFRange(location: 0, length: 0)
    return AXValueGetValue(value as! AXValue, .cfRange, &r) ? r : nil
}

func makeCFRange(_ location: Int, _ length: Int) -> AXValue {
    var r = CFRange(location: location, length: length)
    return AXValueCreate(.cfRange, &r)!
}

// MARK: - Probe

struct Snapshot: Equatable {
    let appName: String
    let bundleId: String
    let role: String
    let valuePreview: String
    let valueLength: Int
    let caretLoc: Int
    let caretLen: Int
    let hasFocusedElement: Bool
}

var lastSnapshot: Snapshot?
var lastFrontmostBundleId: String?

func probe() {
    let systemWide = AXUIElementCreateSystemWide()
    let frontmost = NSWorkspace.shared.frontmostApplication
    let frontmostName = frontmost?.localizedName ?? "?"
    let frontmostBundle = frontmost?.bundleIdentifier ?? "?"

    // Try system-wide first.
    var focusedAny = axCopy(systemWide, kAXFocusedUIElementAttribute as String)
    var systemWideErr = lastAXError
    var route = "system-wide"

    // Fallback: query the frontmost app's AX element directly.
    var perAppErr: AXError = .success
    if focusedAny == nil, let pid = frontmost?.processIdentifier {
        let appEl = AXUIElementCreateApplication(pid)
        focusedAny = axCopy(appEl, kAXFocusedUIElementAttribute as String)
        perAppErr = lastAXError
        if focusedAny != nil { route = "per-app" }
    }

    guard let focusedAny = focusedAny else {
        if frontmostBundle != lastFrontmostBundleId {
            lastFrontmostBundleId = frontmostBundle
            lastSnapshot = nil
            log("=== \(timestamp()) ===")
            log("App:        \(frontmostName)  [\(frontmostBundle)]")
            log("Focused:    ❌ no element via AX")
            log("  system-wide error: \(errName(systemWideErr))")
            log("  per-app error:     \(errName(perAppErr))")
            log("")
        }
        return
    }
    let element = focusedAny as! AXUIElement
    lastFrontmostBundleId = frontmostBundle

    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    let app = NSRunningApplication(processIdentifier: pid)
    let appName = app?.localizedName ?? "?"
    let bundleId = app?.bundleIdentifier ?? "?"

    let role = axCopy(element, kAXRoleAttribute as String) as? String ?? "?"

    let value = axCopy(element, kAXValueAttribute as String) as? String
    let valueLength = value?.count ?? -1
    let valuePreview: String = {
        guard let v = value else { return "<not exposed>" }
        let trimmed = v.count > 80 ? String(v.prefix(80)) + "…" : v
        return "\"" + trimmed.replacingOccurrences(of: "\n", with: "\\n") + "\""
    }()

    let selRange = cfRange(from: axCopy(element, kAXSelectedTextRangeAttribute as String))
    let caretLoc = selRange?.location ?? -1
    let caretLen = selRange?.length ?? -1

    let snap = Snapshot(
        appName: appName, bundleId: bundleId, role: role,
        valuePreview: valuePreview, valueLength: valueLength,
        caretLoc: caretLoc, caretLen: caretLen,
        hasFocusedElement: true
    )
    if snap == lastSnapshot { return }
    lastSnapshot = snap

    var lines: [String] = []
    lines.append("=== \(timestamp()) ===")
    lines.append("App:        \(appName)  [\(bundleId)]   (route: \(route))")
    lines.append("Role:       \(role)")

    if let pos = cgPoint(from: axCopy(element, kAXPositionAttribute as String)),
       let size = cgSize(from: axCopy(element, kAXSizeAttribute as String)) {
        lines.append("Frame:      origin=(\(fmt(pos.x)), \(fmt(pos.y)))  size=(\(fmt(size.width))×\(fmt(size.height)))")
    } else {
        lines.append("Frame:      <not exposed>")
    }

    lines.append("Value:      \(valueLength >= 0 ? "\(valueLength) chars  " : "")\(valuePreview)")

    if let range = selRange {
        lines.append("Selected:   loc=\(range.location)  len=\(range.length)")

        // Bounds for the character at the caret (or just before it if at end).
        let probeRange: AXValue
        if range.location > 0 {
            probeRange = makeCFRange(range.location - 1, 1)
        } else {
            probeRange = makeCFRange(0, 1)
        }
        if let boundsAny = axCopyParam(element, kAXBoundsForRangeParameterizedAttribute as String, probeRange),
           let rect = cgRect(from: boundsAny) {
            lines.append("Caret rect: \(rectFmt(rect))   ← position the overlay HERE")
        } else {
            lines.append("Caret rect: <not exposed>")
        }

        // Attributed string near the caret — gives us font + color.
        // AX uses its own attribute keys, not Cocoa's, so dump everything.
        if range.location > 0,
           let attrAny = axCopyParam(element, kAXAttributedStringForRangeParameterizedAttribute as String, makeCFRange(range.location - 1, 1)),
           let attr = attrAny as? NSAttributedString, attr.length > 0 {
            let attrs = attr.attributes(at: 0, effectiveRange: nil)
            lines.append("AttrKeys:   \(attrs.keys.map { $0.rawValue }.sorted().joined(separator: ", "))")

            // AX font attribute: a dict with AXFontName/AXFontFamily/AXFontSize.
            if let axFont = attrs[NSAttributedString.Key("AXFont")] as? [String: Any] {
                let name = axFont["AXFontName"] as? String ?? "?"
                let family = axFont["AXFontFamily"] as? String ?? "?"
                let size = axFont["AXFontSize"] as? Double ?? -1
                lines.append("AX Font:    name=\(name)  family=\(family)  size=\(size)")
            }
            if let cocoaFont = attrs[.font] as? NSFont {
                lines.append("Cocoa Font: \(cocoaFont.fontName)  \(cocoaFont.pointSize)pt")
            }
            if attrs[NSAttributedString.Key("AXForegroundColor")] != nil {
                lines.append("AX Color:   present (CGColor)")
            }
            if let cocoaColor = attrs[.foregroundColor] as? NSColor {
                lines.append("Cocoa Color: \(cocoaColor)")
            }
        } else {
            lines.append("AttrString: <not exposed>")
        }
    } else {
        lines.append("Selected:   <not exposed>")
    }

    lines.append("")
    log(lines.joined(separator: "\n"))
    log("")
}

func fmt(_ d: CGFloat) -> String {
    String(format: "%.0f", d)
}
func rectFmt(_ r: CGRect) -> String {
    "x=\(fmt(r.minX)) y=\(fmt(r.minY)) w=\(fmt(r.width)) h=\(fmt(r.height))"
}
func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}

// MARK: - Main

ensureAccessibility()

log("AX probe running. Switch to any app, focus a text field, type a few keys.")
log("Logging to: \(logURL.path)")
log("Snapshots print only when something changes. Ctrl+C to stop.")
log("")

let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in probe() }
RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run()
