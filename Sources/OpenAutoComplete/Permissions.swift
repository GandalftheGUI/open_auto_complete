import Cocoa
import ApplicationServices
import CoreGraphics

enum Permissions {
    /// Returns true if Accessibility is already granted. Otherwise pops the system prompt
    /// and returns false (the app needs to be re-launched after the user grants).
    static func ensureAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Returns true if Screen Recording is already granted, false otherwise. If not
    /// granted, this triggers the system permission prompt (despite the "Request"
    /// name, the API actually does both check + prompt). User must restart the app
    /// after granting for capture to start working.
    static func ensureScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }
}
