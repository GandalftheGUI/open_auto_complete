import Foundation

/// Optimistic mirror of the focused field's text — seeded from AX on focus-in,
/// extended by the CGEvent tap as keystrokes flow through us, invalidated when
/// we can't cheaply keep it in sync (arrow keys, modifier combos, mouse clicks,
/// focus switches).
///
/// Consumers read `currentValue(for:)` to get an instant, up-to-date string
/// without waiting for AX to catch up after a keystroke. When the buffer is
/// invalid, callers should fall back to AX.
///
/// Not an actor — accessed only from the main thread (event tap callbacks hop
/// to main before touching this).
final class KeystrokeBuffer {

    private var value: String = ""
    private var bundleId: String = ""
    private var isValid: Bool = false

    /// Initialize or reseed from a known-good AX read. `axCaretAtEnd` should be
    /// true when the caret is at the end of the field — that's the only regime
    /// where naive append/backspace can keep us in sync.
    func seed(axValue: String, axCaretAtEnd: Bool, bundleId: String) {
        self.value = axValue
        self.bundleId = bundleId
        self.isValid = axCaretAtEnd
    }

    /// Flag the buffer as out of sync without dropping the stored text (so the
    /// next AX read will re-seed it).
    func invalidate() {
        isValid = false
    }

    /// Append a typed character to our mirror.
    func appendCharacter(_ c: Character, for bundleId: String) {
        guard isValid, bundleId == self.bundleId else { return }
        value.append(c)
    }

    /// Shrink the mirror by one char on backspace. Assumes caret at end.
    func backspace(for bundleId: String) {
        guard isValid, bundleId == self.bundleId else { return }
        if !value.isEmpty { value.removeLast() }
    }

    /// Current optimistic value for `bundleId`, or nil if the buffer is stale or
    /// belongs to a different app.
    func currentValue(for bundleId: String) -> String? {
        guard isValid, bundleId == self.bundleId else { return nil }
        return value
    }

    /// Reconcile with a fresh AX read. If we've extended beyond AX (AX is just
    /// lagging), keep our buffer. Otherwise AX has information we don't (paste,
    /// autocorrect, undo) and wins.
    func reconcile(axValue: String, axCaretAtEnd: Bool, bundleId: String) {
        if bundleId != self.bundleId {
            seed(axValue: axValue, axCaretAtEnd: axCaretAtEnd, bundleId: bundleId)
            return
        }
        if !isValid {
            seed(axValue: axValue, axCaretAtEnd: axCaretAtEnd, bundleId: bundleId)
            return
        }
        if value == axValue {
            return  // in sync, nothing to do
        }
        if value.hasPrefix(axValue) {
            // We're ahead — AX just hasn't caught up yet. Keep our buffer.
            return
        }
        // AX has content we don't (paste? autocorrect?) — AX wins.
        seed(axValue: axValue, axCaretAtEnd: axCaretAtEnd, bundleId: bundleId)
    }
}
