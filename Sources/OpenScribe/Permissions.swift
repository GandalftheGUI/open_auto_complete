import Cocoa
import ApplicationServices

enum Permissions {
    /// Returns true if Accessibility is already granted. Otherwise pops the system prompt
    /// and returns false (the app needs to be re-launched after the user grants).
    static func ensureAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
}
