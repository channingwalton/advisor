import AppKit
import SwiftUI

/// The window that a SwiftUI view is in. `HostWindow.Reader` keeps it up to
/// date, also when a reopened scene puts the view in a new window.
final class HostWindow {
    private(set) weak var window: NSWindow?

    /// Whether `other` is the host window, or a window attached to it. A
    /// popover, such as the Ask or Note popover, is a window of its own, and a
    /// child window of the window of its anchor.
    func holds(_ other: NSWindow?) -> Bool {
        guard let window else { return false }
        var candidate = other
        while let current = candidate {
            if current === window { return true }
            candidate = current.parent
        }
        return false
    }

    /// Whether an editable text field has the keyboard focus in the host
    /// window or in one of its popovers. `keyWindow` is the window that has
    /// the keyboard focus. A field in another window, such as Preferences,
    /// does not count (issue #123). A focused `NSTextField` edits through a
    /// field-editor `NSTextView`. The selectable transcript is a non-editable
    /// `NSTextView`, so `isEditable` tells them apart (issue #37).
    func isEditingText(keyWindow: NSWindow?) -> Bool {
        guard holds(keyWindow), let field = keyWindow?.firstResponder as? NSTextView else { return false }
        return field.isEditable
    }

    /// Floats the host window above other windows and on all Spaces, or puts
    /// it back at the normal level. Another window, such as the key window,
    /// does not change (issue #123).
    func float(_ on: Bool) {
        guard let window else { return }
        window.level = on ? .floating : .normal
        window.collectionBehavior = on ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
    }

    /// A zero-size view that records the window it is in.
    struct Reader: NSViewRepresentable {
        let host: HostWindow

        func makeNSView(context: Context) -> NSView { Marker(host: host) }
        func updateNSView(_ nsView: NSView, context: Context) {}

        private final class Marker: NSView {
            let host: HostWindow

            init(host: HostWindow) {
                self.host = host
                super.init(frame: .zero)
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) { nil }

            /// Records a new window only: a marker that leaves its window
            /// after a reopen must not clear the window that a newer marker
            /// recorded. The reference is weak, so a closed window goes.
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if let window { host.window = window }
            }
        }
    }
}
