import AppKit
import Testing

@testable import Advisor

@Test func noAgentsClosesImmediately() {
    // The prompt never appears when nothing is running, whatever the choice.
    #expect(SessionClose.action(agentsInFlight: false, choice: .wait) == .closeNow)
    #expect(SessionClose.action(agentsInFlight: false, choice: .terminate) == .closeNow)
    #expect(SessionClose.action(agentsInFlight: false, choice: .cancel) == .closeNow)
}

@Test func waitChoiceWaitsThenCloses() {
    #expect(SessionClose.action(agentsInFlight: true, choice: .wait) == .waitThenClose)
}

@Test func terminateChoiceStopsThenCloses() {
    #expect(SessionClose.action(agentsInFlight: true, choice: .terminate) == .terminateAndClose)
}

@Test func cancelChoiceKeepsWindowOpen() {
    #expect(SessionClose.action(agentsInFlight: true, choice: .cancel) == .stayOpen)
}

/// Takes focus whatever the keyboard-navigation setting, unlike a button.
private final class FocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private func window(title: String) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
        styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.title = title
    return window
}

/// The close log names the control that holds focus in each window, so the
/// next hang on close shows which control AppKit was moving focus away from.
@MainActor
@Test func req_close_log() {
    let recording = window(title: "Recording")
    let focused = FocusView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
    recording.contentView?.addSubview(focused)
    #expect(recording.makeFirstResponder(focused))

    // An untitled window (a popover's) goes by its class; a text field being
    // edited by the field editor that edits it.
    let popover = window(title: "")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
    popover.contentView?.addSubview(field)
    #expect(popover.makeFirstResponder(field))

    let idle = window(title: "Sessions")

    #expect(SessionClose.logLine(agentsInFlight: true, windows: [recording, popover, idle])
        == "[advisor] recording close: agents running: true; first responders: "
        + "Recording=FocusView, NSWindow=field editor of NSTextField, Sessions=window")
    #expect(SessionClose.logLine(choice: .wait) == "[advisor] recording close: choice wait")
}

/// The close guard writes the line before it decides, on the path with no
/// prompt (the prompt's path needs a modal alert, so it is not driven here).
@MainActor
@Test func closeGuardLogsTheClose() {
    let coordinator = WindowCloseGuard.Coordinator()
    var lines: [String] = []
    coordinator.log = { lines.append($0) }
    coordinator.update(agentsInFlight: { false }, isFinishing: { false }, terminate: {}, waitForIdle: {})
    #expect(coordinator.windowShouldClose(window(title: "Recording")))
    #expect(lines.count == 1)
    #expect(lines.first?.hasPrefix("[advisor] recording close: agents running: false; first responders: ") == true)
}
