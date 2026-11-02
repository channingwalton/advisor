import AppKit
import SwiftUI

/// The window that a SwiftUI view is in. `HostWindow.Reader` keeps it up to
/// date, also when a reopened scene puts the view in a new window.
final class HostWindow {
    private(set) weak var window: NSWindow?

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
