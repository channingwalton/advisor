import AppKit
import SwiftUI
import Testing

@testable import Advisor

// AppKit shows a tooltip only while the app is active unless its window allows
// otherwise. Advisor floats over the meeting app, so every `.help` stayed
// hidden until a click brought it forward (issue #105).

@MainActor
private func window<V: View>(hosting view: V) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 120, height: 40),
        styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: view)
    window.layoutIfNeeded()
    return window
}

@MainActor
@Test func aWindowShowsItsToolTipsWhileAdvisorIsInTheBackground() {
    #expect(window(hosting: Text("Feed").showsToolTipsWhenInactive())
        .allowsToolTipsWhenApplicationIsInactive)
}

@MainActor
@Test func aWindowShowsToolTipsOnlyWhileActiveByDefault() {
    #expect(!window(hosting: Text("Feed")).allowsToolTipsWhenApplicationIsInactive)
}

// A reopened scene builds a fresh window, so the flag must follow the view
// into each window it lands in, not be set once when the view is made.
@MainActor
@Test func aViewMovedToAFreshWindowSetsTheFlagThereToo() {
    let first = window(hosting: Text("Feed").showsToolTipsWhenInactive())
    let fresh = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 120, height: 40),
        styleMask: [.titled], backing: .buffered, defer: true)
    fresh.isReleasedWhenClosed = false
    fresh.contentView = first.contentView
    #expect(fresh.allowsToolTipsWhenApplicationIsInactive)
}
