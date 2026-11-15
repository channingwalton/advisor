import Foundation
import Testing

@testable import Advisor

/// The result of each `take`, at `start` plus each offset in seconds.
private func takes(_ budget: inout RestartBudget, at offsets: [TimeInterval]) -> [Bool] {
    let start = Date(timeIntervalSince1970: 1_000)
    return offsets.map { budget.take(at: start.addingTimeInterval($0)) }
}

@Test func restartBudgetAllowsTheLimitWithinTheWindow() {
    var budget = RestartBudget(limit: 3, window: 60)

    let results = takes(&budget, at: [0, 1, 2, 3])
    #expect(results == [true, true, true, false])
}

@Test func restartBudgetRefillsAsAttemptsLeaveTheWindow() {
    var budget = RestartBudget(limit: 2, window: 60)

    // At 61 s the first attempt is more than 60 s old.
    let results = takes(&budget, at: [0, 30, 59, 61, 62])
    #expect(results == [true, true, false, true, false])
}

@Test func restartBudgetRefusalDoesNotUseAnAttempt() {
    var budget = RestartBudget(limit: 1, window: 60)

    let results = takes(&budget, at: [0, 10, 50, 61])
    #expect(results == [true, false, false, true])
}

@Test func captureRecoveryNotesNameTheSource() {
    #expect(CaptureRecovery.restartingNote(.microphone) == "microphone stopped; restarting…")
    #expect(CaptureRecovery.restartingNote(.systemAudio) == "system audio stopped; restarting…")
    #expect(
        CaptureRecovery.restartedNote(.microphone, listening: "listening — default input")
            == "listening — default input | microphone restarted")
}

@Test func captureRecoveryFailureNoteGivesTheError() {
    let note = CaptureRecovery.failedNote(
        .microphone, listening: "listening — USB mic",
        error: AdvisorError.audioSetup("cannot find input device USB mic for capture"))

    #expect(
        note == "listening — USB mic | microphone stopped and could not restart: "
            + "audio setup failed: cannot find input device USB mic for capture")
}

@Test func captureRecoveryFailureNoteWithoutAnErrorSaysItStoppedTooOften() {
    let note = CaptureRecovery.failedNote(
        .systemAudio, listening: "listening — default input + system audio", error: nil)

    #expect(
        note == "listening — default input + system audio | "
            + "system audio stopped too often to restart; press Stop, then Resume")
}

@Test func captureRecoveryFailureNoteForAPermissionErrorAsksForThePermission() {
    let error = NSError(
        domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
        code: -3801,
        userInfo: [NSLocalizedDescriptionKey: "The user declined TCCs for application, window, display capture"])

    #expect(
        CaptureRecovery.failedNote(.systemAudio, listening: "listening", error: error)
            == "listening | \(SystemAudioCapture.permissionRequiredNote)")
}
