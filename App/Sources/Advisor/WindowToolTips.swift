import AppKit
import SwiftUI

extension View {
    /// Let the window hosting this view show `.help` tooltips while Advisor is
    /// in the background. AppKit shows a tooltip only in the active app unless
    /// the window allows otherwise, and Advisor's usual place is floating over
    /// the meeting app — so its tooltips stayed hidden until a click brought it
    /// forward (issue #105). Apply once per scene's root view; popovers need
    /// none, as they close when the app resigns active.
    func showsToolTipsWhenInactive() -> some View {
        background(ToolTipsWhenInactive())
    }
}

/// An empty view that sets the flag on whichever window it lands in, each
/// time it lands in one (a reopened scene gets a fresh window).
private struct ToolTipsWhenInactive: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FlagView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class FlagView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.allowsToolTipsWhenApplicationIsInactive = true
        }
    }
}
