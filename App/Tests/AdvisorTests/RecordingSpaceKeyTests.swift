import AppKit
import SwiftUI
import Testing

@testable import Advisor

// Issue #111: Space in another Advisor window, such as the Sessions browser,
// started or stopped the recording.

@MainActor
private func window() -> NSWindow {
    _ = NSApplication.shared
    return NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                    backing: .buffered, defer: false)
}

@MainActor
private func key(_ code: UInt16, in window: NSWindow, modifiers: NSEvent.ModifierFlags = [],
                 isARepeat: Bool = false) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: " ",
        charactersIgnoringModifiers: " ", isARepeat: isARepeat, keyCode: code)!
}

@MainActor
@Test func spaceInTheRecordingWindowToggles() {
    let recording = window()
    #expect(RecordingSpaceKey.effect(of: key(49, in: recording), recordingWindow: recording) == .toggle)
}

@MainActor
@Test func spaceInAnotherWindowDoesNotToggle() {
    let recording = window()
    let sessions = window()
    #expect(RecordingSpaceKey.effect(of: key(49, in: sessions), recordingWindow: recording) == .pass)
    #expect(RecordingSpaceKey.effect(of: key(49, in: sessions), recordingWindow: nil) == .pass)
}

@MainActor
@Test func otherKeysAndModifiedSpaceDoNotToggle() {
    let recording = window()
    #expect(RecordingSpaceKey.effect(of: key(0, in: recording), recordingWindow: recording) == .pass)
    #expect(RecordingSpaceKey.effect(of: key(49, in: recording, modifiers: .command),
                                     recordingWindow: recording) == .pass)
}

@MainActor
@Test func spaceInAnEditableFieldOfTheRecordingWindowTypesASpace() {
    let recording = window()
    let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
    recording.contentView?.addSubview(field)
    #expect(recording.makeFirstResponder(field))
    #expect(RecordingSpaceKey.effect(of: key(49, in: recording), recordingWindow: recording) == .pass)
    // A held Space in the field types more spaces.
    #expect(RecordingSpaceKey.effect(of: key(49, in: recording, isARepeat: true),
                                     recordingWindow: recording) == .pass)
    // The selectable transcript is a non-editable text view: Space still toggles.
    field.isEditable = false
    #expect(RecordingSpaceKey.effect(of: key(49, in: recording), recordingWindow: recording) == .toggle)
}

// Issue #122: a held Space toggled the recording again on each key repeat.
@MainActor
@Test func aHeldSpaceTogglesOnceAndItsRepeatsStopAtTheMonitor() {
    let recording = window()
    #expect(RecordingSpaceKey.effect(of: key(49, in: recording), recordingWindow: recording) == .toggle)
    // A repeat does nothing, and does not go on to the window, which would beep.
    #expect(RecordingSpaceKey.effect(of: key(49, in: recording, isARepeat: true),
                                     recordingWindow: recording) == .ignore)
    // A repeat in another window is that window's event.
    let sessions = window()
    #expect(RecordingSpaceKey.effect(of: key(49, in: sessions, isARepeat: true),
                                     recordingWindow: recording) == .pass)
}

@MainActor
@Test func theHostWindowFollowsTheViewToANewWindowAndKeepsItWhenAnOldMarkerLeaves() {
    let host = HostWindow()
    let first = window()
    // The hosting view makes the marker view at its first layout.
    first.contentView = NSHostingView(rootView: HostWindow.Reader(host: host))
    first.contentView?.layoutSubtreeIfNeeded()
    #expect(host.window === first)
    // A reopen: a new view in a new window, then the old view leaves its window.
    let second = window()
    second.contentView = NSHostingView(rootView: HostWindow.Reader(host: host))
    second.contentView?.layoutSubtreeIfNeeded()
    #expect(host.window === second)
    first.contentView = nil
    #expect(host.window === second)
}
