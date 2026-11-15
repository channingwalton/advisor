import AppKit

/// Space as the Listen, Stop and Resume key of the recording window, and Esc
/// as its Stop key.
enum RecordingSpaceKey {
    static let keyCode: UInt16 = 49
    static let escapeKeyCode: UInt16 = 53

    /// What the key monitor does with a key event.
    enum Effect: Equatable {
        /// Not the recording key: the event goes on to its window.
        case pass
        /// Space: Listen, Stop or Resume. The event stops at the monitor.
        case toggle
        /// Esc: Stop, while recording.
        case stop
        /// A key repeat of a held Space or Esc. The event stops at the monitor
        /// and nothing happens, so the press acts once (issue #122). The repeat
        /// does not go on to the window, which has no use for it and beeps.
        case ignore
    }

    /// `.toggle` for Space and `.stop` for Esc with no modifier, in the
    /// recording window, and not while an editable text field there has the
    /// focus, where Space must type a space and Esc belongs to the field
    /// (issue #138). The key monitor gets the key events of every Advisor
    /// window, so Space in another window, such as the Sessions browser,
    /// toggled the recording (issue #111). The selectable transcript is a
    /// non-editable text view, so it still toggles and stops.
    static func effect(of event: NSEvent, recordingWindow: NSWindow?) -> Effect {
        guard event.type == .keyDown, event.keyCode == keyCode || event.keyCode == escapeKeyCode,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              let window = event.window, window === recordingWindow
        else { return .pass }
        if let field = window.firstResponder as? NSTextView, field.isEditable { return .pass }
        if event.isARepeat { return .ignore }
        return event.keyCode == keyCode ? .toggle : .stop
    }
}
