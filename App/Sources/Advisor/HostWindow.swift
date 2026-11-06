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

    /// Whether Float is on. A window that `Reader` records while Float is on
    /// floats too (issue #132).
    private var floatIsOn = false

    /// The window that Float floated, and its level and collection behaviour
    /// before that.
    private weak var floated: NSWindow?
    private var levelBeforeFloat: NSWindow.Level = .normal
    private var behaviourBeforeFloat: NSWindow.CollectionBehavior = []

    /// Floats the host window above other windows and on all Spaces, or puts
    /// it back. Another window, such as the key window, does not change
    /// (issue #123). The window keeps its own collection behaviour, such as
    /// `.auxiliary`, and gets it back at Float off (issue #130). Float on
    /// again sets the floating behaviour again: SwiftUI changes it at a close
    /// (issue #132).
    func float(_ on: Bool) {
        floatIsOn = on
        applyFloat()
    }

    /// Records the window that the view moved into. While Float is on, the
    /// new window floats, and the old one gets its own level and collection
    /// behaviour back (issue #132).
    private func record(_ new: NSWindow) {
        window = new
        applyFloat()
    }

    /// Floats the host window while Float is on, and puts back a window that
    /// Float floated and that no longer floats. AppKit raises an exception for
    /// a window that both moves to the active Space and joins all Spaces, so a
    /// floating window does not move.
    private func applyFloat() {
        if !floatIsOn || floated !== window { putBack() }
        guard floatIsOn, let window else { return }
        if floated == nil {
            floated = window
            levelBeforeFloat = window.level
            behaviourBeforeFloat = window.collectionBehavior
        }
        window.level = .floating
        window.collectionBehavior = behaviourBeforeFloat
            .subtracting(.moveToActiveSpace)
            .union([.canJoinAllSpaces, .fullScreenAuxiliary])
    }

    /// Gives the window that Float floated its own level and collection
    /// behaviour back. A window that Float did not float does not change.
    private func putBack() {
        guard let window = floated else { return }
        window.level = levelBeforeFloat
        window.collectionBehavior = behaviourBeforeFloat
        floated = nil
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
                if let window { host.record(window) }
            }
        }
    }
}
