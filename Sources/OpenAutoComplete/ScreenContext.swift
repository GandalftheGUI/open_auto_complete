import Foundation
import CoreGraphics
import Vision
import AppKit
import ApplicationServices

/// A single recognized line of text plus its bounding rect in AX screen coordinates
/// (top-left origin, pixels).
struct OCRLine {
    let text: String
    let bounds: CGRect
}

/// An OCR capture of a window — the full text, per-line bounds, and the window's
/// screen rect at the time of capture.
struct OCRCapture {
    let bundleId: String
    let windowBounds: CGRect
    let lines: [OCRLine]
    let timestamp: Date

    var joinedText: String { lines.map(\.text).joined(separator: "\n") }
}

/// Captures the currently focused window and runs Apple's Vision OCR on the pixels.
/// Provides text + per-line positions for surfaces where AX can't or won't expose it.
enum ScreenContext {

    /// Capture the focused window of the frontmost app and OCR it. Returns nil on
    /// any failure (missing permission, no focused window, etc).
    static func captureFocusedWindow() async -> OCRCapture? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundleId = app.bundleIdentifier ?? "?"

        guard let bounds = focusedWindowBounds(for: app) else {
            Log.shared.line("OCR: no focused window bounds for \(bundleId)")
            return nil
        }
        Log.shared.line("OCR: capturing \(bundleId) region \(rectFmt(bounds))")

        guard let image = CGWindowListCreateImage(
            bounds,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.boundsIgnoreFraming, .nominalResolution]
        ) else {
            Log.shared.line("OCR: capture failed (Screen Recording denied?)")
            return nil
        }

        let t0 = Date()
        let lines = await runOCR(on: image, windowBounds: bounds)
        let elapsed = Int(Date().timeIntervalSince(t0) * 1000)
        Log.shared.line("OCR: \(elapsed)ms  \(lines.count) lines, \(lines.map(\.text.count).reduce(0, +)) total chars")

        return OCRCapture(
            bundleId: bundleId,
            windowBounds: bounds,
            lines: lines,
            timestamp: Date()
        )
    }

    // MARK: - Helpers

    /// Read the focused window's screen-space rect via AX.
    private static func focusedWindowBounds(for app: NSRunningApplication) -> CGRect? {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)

        var winAny: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winAny) == .success,
              let win = winAny else { return nil }
        let winEl = win as! AXUIElement

        var posAny: CFTypeRef?
        var sizeAny: CFTypeRef?
        guard AXUIElementCopyAttributeValue(winEl, kAXPositionAttribute as CFString, &posAny) == .success,
              AXUIElementCopyAttributeValue(winEl, kAXSizeAttribute as CFString, &sizeAny) == .success,
              let pv = posAny, let sv = sizeAny else { return nil }

        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sv as! AXValue, .cgSize, &size) else { return nil }

        return CGRect(origin: pos, size: size)
    }

    private static func runOCR(on image: CGImage, windowBounds: CGRect) async -> [OCRLine] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[OCRLine], Never>) in
            let request = VNRecognizeTextRequest { req, _ in
                guard let observations = req.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }
                let lines = observations.compactMap { obs -> OCRLine? in
                    guard let text = obs.topCandidates(1).first?.string, !text.isEmpty else {
                        return nil
                    }
                    return OCRLine(
                        text: text,
                        bounds: Self.screenRect(fromNormalized: obs.boundingBox, inWindow: windowBounds)
                    )
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                Log.shared.line("OCR: handler error \(error)")
                continuation.resume(returning: [])
            }
        }
    }

    /// Vision uses bottom-left origin + normalized (0–1) coords relative to the image.
    /// AX screen coords are top-left origin in pixels relative to primary display.
    /// Convert: flip Y inside the image, then offset by window's screen origin.
    private static func screenRect(fromNormalized bbox: CGRect, inWindow window: CGRect) -> CGRect {
        let xInWin = bbox.minX * window.width
        let yInWin = (1 - bbox.maxY) * window.height
        let w = bbox.width * window.width
        let h = bbox.height * window.height
        return CGRect(
            x: window.minX + xInWin,
            y: window.minY + yInWin,
            width: w,
            height: h
        )
    }

    private static func rectFmt(_ r: CGRect) -> String {
        "(x=\(Int(r.minX)),y=\(Int(r.minY)),w=\(Int(r.width))×\(Int(r.height)))"
    }
}

/// Singleton cache holding the most recent OCR capture. Re-captured when the user
/// switches focus between apps. Lookup by app bundle ID so we don't serve a stale
/// Brave capture to a TextEdit prompt.
actor OCRCache {
    static let shared = OCRCache()

    private var latest: OCRCapture?
    private var inFlight: Task<Void, Never>?

    /// Kick off a capture in the background. Cancels any previous in-flight capture.
    /// Updates `latest` when done. No return value — callers just read `current()`.
    func startCapture() {
        inFlight?.cancel()
        inFlight = Task {
            if let cap = await ScreenContext.captureFocusedWindow() {
                self.latest = cap
            }
        }
    }

    /// Most recent capture if its bundleId matches `bundleId`. Returns nil if the
    /// cache is stale (belongs to a different app).
    func current(for bundleId: String) -> OCRCapture? {
        guard let cap = latest, cap.bundleId == bundleId else { return nil }
        return cap
    }

    /// Find the OCR line whose text ends with (or contains as suffix) `typedTail`.
    /// Returns the matched line. Optionally restricts search to observations that
    /// intersect `within`, which we use to avoid matching the same text elsewhere
    /// on the page (AX fieldFrame is typically correct even when caret is garbage).
    func findAnchor(typedTail: String, for bundleId: String, within searchRegion: CGRect?) -> OCRLine? {
        guard let cap = latest, cap.bundleId == bundleId else { return nil }
        let needle = typedTail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard needle.count >= 3 else { return nil }

        var bestMatch: OCRLine?
        for line in cap.lines {
            if let searchRegion, !searchRegion.intersects(line.bounds) {
                continue
            }
            let haystack = line.text.lowercased()
            if haystack.hasSuffix(needle) || haystack.contains(needle) {
                bestMatch = line  // prefer last match (typically most recent text)
            }
        }
        return bestMatch
    }
}
