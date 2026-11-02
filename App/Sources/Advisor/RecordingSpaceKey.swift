import AppKit

/// Space as the Listen, Stop and Resume key of the recording window.
enum RecordingSpaceKey {
    static let keyCode: UInt16 = 49

    /// Whether `event` toggles the recording: Space with no modifier, in the
    /// recording window, and not while an editable text field there has the
    /// focus, where Space must type a space. The key monitor gets the key
    /// events of every Advisor window, so Space in another window, such as the
    /// Sessions browser, toggled the recording (issue #111). The selectable
    /// transcript is a non-editable text view, so it still toggles.
    static func toggles(_ event: NSEvent, recordingWindow: NSWindow?) -> Bool {
        guard event.type == .keyDown, event.keyCode == keyCode,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              let window = event.window, window === recordingWindow
        else { return false }
        if let field = window.firstResponder as? NSTextView, field.isEditable { return false }
        return true
    }
}
