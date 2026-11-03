import AppKit
import SwiftUI
import Testing

@testable import Advisor

// Issue #123: the live feed and Float on Top looked at the app's key window,
// not at the recording window.

@MainActor
private func window() -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    return window
}

/// A window that holds a `HostWindow.Reader` for `host`, as the recording window does.
@MainActor
private func hostedWindow(_ host: HostWindow) -> NSWindow {
    let window = window()
    let reader = NSHostingView(rootView: HostWindow.Reader(host: host))
    window.contentView?.addSubview(reader)
    reader.layoutSubtreeIfNeeded()
    return window
}

@MainActor
private func focusEditableField(in window: NSWindow, editable: Bool = true) {
    let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
    field.isEditable = editable
    window.contentView?.addSubview(field)
    #expect(window.makeFirstResponder(field))
}

@MainActor
@Test func aPopoverOfTheHostWindowBelongsToItAndAnotherWindowDoesNot() {
    let host = HostWindow()
    let recording = hostedWindow(host)
    #expect(host.holds(recording))
    #expect(!host.holds(window()))
    #expect(!host.holds(nil))
    // The Ask and Note popovers are windows of their own.
    let anchor = NSView(frame: NSRect(x: 10, y: 10, width: 20, height: 20))
    recording.contentView?.addSubview(anchor)
    recording.orderFront(nil)
    let popover = NSPopover()
    let content = NSViewController()
    content.view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
    popover.contentViewController = content
    popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    let popoverWindow = content.view.window
    #expect(popoverWindow != nil)
    #expect(popoverWindow !== recording)
    #expect(host.holds(popoverWindow))
    popover.close()
    recording.orderOut(nil)
}

@MainActor
@Test func aFieldInTheHostWindowOrItsPopoverStopsTheFeed() {
    let host = HostWindow()
    let recording = hostedWindow(host)
    #expect(!host.isEditingText(keyWindow: recording))
    focusEditableField(in: recording)
    #expect(host.isEditingText(keyWindow: recording))
    // A popover, as a child window of the recording window.
    let popover = window()
    recording.addChildWindow(popover, ordered: .above)
    focusEditableField(in: popover)
    #expect(host.isEditingText(keyWindow: popover))
    recording.removeChildWindow(popover)
}

@MainActor
@Test func aFieldInAnotherWindowDoesNotStopTheFeed() {
    let host = HostWindow()
    let recording = hostedWindow(host)
    focusEditableField(in: recording)
    // Preferences has the keyboard focus, so nobody types in the recording window.
    let preferences = window()
    focusEditableField(in: preferences)
    #expect(!host.isEditingText(keyWindow: preferences))
    #expect(!host.isEditingText(keyWindow: nil))
    // The selectable transcript is a non-editable text view.
    let other = HostWindow()
    let second = hostedWindow(other)
    focusEditableField(in: second, editable: false)
    #expect(!other.isEditingText(keyWindow: second))
}

@MainActor
@Test func floatChangesTheHostWindowOnly() {
    let host = HostWindow()
    let recording = hostedWindow(host)
    let preferences = window()
    let before = recording.collectionBehavior
    host.float(true)
    #expect(recording.level == .floating)
    #expect(recording.collectionBehavior.contains(.canJoinAllSpaces))
    #expect(preferences.level == .normal)
    host.float(false)
    #expect(recording.level == .normal)
    #expect(recording.collectionBehavior == before)
    // With no window yet, nothing floats.
    HostWindow().float(true)
    #expect(preferences.level == .normal)
}
