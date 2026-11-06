import Testing
import Foundation

@testable import Advisor

// ⌘Q must let the recording finish tearing down — speech finals, the 1.5 s echo
// delay, the final note save — before the process exits, but a wedged speech
// engine must not stop the app quitting (code review 2026-10-06).

@MainActor
@Test func quitWaitsForTheShutdownBeforeExiting() async {
    var events: [String] = []
    let quit = QuitSequence(timeout: .seconds(5), exit: { events.append("exit") })
    let task = quit.start(
        shutdown: {
            try? await Task.sleep(for: .milliseconds(50)) // the speech engine finishing
            events.append("shutdown")
        },
        finish: { events.append("finish") })
    await task?.value
    #expect(events == ["shutdown", "finish", "exit"])
}

/// A wedged teardown is cut off at the deadline, and the final save still runs.
/// The time bound is loose on purpose: the shutdown sleeps for an hour, so any
/// bound far below that proves the cut-off. A tight bound measured the CI
/// runner, where other tests can hold the main actor for seconds (run
/// 42300778196 took 3 s).
@MainActor
@Test func req_quit_deadline() async {
    var events: [String] = []
    let quit = QuitSequence(timeout: .milliseconds(100), exit: { events.append("exit") })
    let start = ContinuousClock.now
    let task = quit.start(
        shutdown: { try? await Task.sleep(for: .seconds(3600)) }, // never finishes in time
        finish: { events.append("finish") })
    await task?.value
    #expect(events == ["finish", "exit"])
    #expect(ContinuousClock.now - start < .seconds(60))
}

@MainActor
@Test func aSecondQuitWhileWaitingDoesNothing() async {
    var runs = 0
    var exits = 0
    let quit = QuitSequence(timeout: .seconds(5), exit: { exits += 1 })
    let first = quit.start(shutdown: { runs += 1 }, finish: {})
    let second = quit.start(shutdown: { runs += 1 }, finish: {})
    #expect(second == nil)
    await first?.value
    #expect(runs == 1)
    #expect(exits == 1)
}
