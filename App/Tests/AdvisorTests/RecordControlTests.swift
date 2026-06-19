import Foundation
import Testing

@testable import Advisor

@Test func listeningIsRecordingRegardlessOfStoppedFlag() {
    #expect(RecordControl.state(listening: true, stopped: false) == .recording)
    // A stopped-flag residue during resume start-up still reads as recording.
    #expect(RecordControl.state(listening: true, stopped: true) == .recording)
}

@Test func notListeningWithStoppedSessionIsResumable() {
    #expect(RecordControl.state(listening: false, stopped: true) == .stopped)
}

@Test func noSessionIsIdle() {
    #expect(RecordControl.state(listening: false, stopped: false) == .idle)
}

@Test func resumeExcludesTheStoppedSpanFromElapsed() {
    let start = Date(timeIntervalSince1970: 1_000)
    let stoppedAt = Date(timeIntervalSince1970: 1_030) // 30 s of recording
    let now = Date(timeIntervalSince1970: 1_100) // stopped for 70 s
    let resumed = RecordControl.resumedStart(start, stoppedAt: stoppedAt, now: now)
    // Elapsed at the resume moment must still read 30 s, not 100 s.
    #expect(now.timeIntervalSince(resumed) == 30)
    #expect(resumed == Date(timeIntervalSince1970: 1_070))
}
