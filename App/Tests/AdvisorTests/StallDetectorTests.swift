import Foundation
import Testing

@testable import Advisor

// The 2026-10-31 close hang left no trace of its own: the main thread stopped
// answering and nothing logged why. The watchdog samples the process once a
// stall passes the threshold; `StallDetector` decides when that is.

private let t0 = SuspendingClock().now

private func at(_ seconds: Double) -> SuspendingClock.Instant { t0 + .seconds(seconds) }

/// Whether `detector` sends a ping at `seconds` after `t0`.
private func ping(_ detector: inout StallDetector, at seconds: Double) -> Bool {
    detector.ping(at: at(seconds))
}

/// The stall lengths `detector` reports, of checks at `seconds` after `t0`.
private func stalls(_ detector: inout StallDetector, at seconds: [Double]) -> [Duration] {
    seconds.compactMap { detector.check(at: at($0)) }
}

@Test func req_stall_sample() {
    var detector = StallDetector(threshold: .seconds(5))
    #expect(ping(&detector, at: 0))
    // One sample per stall, not one per check while it lasts, and the log
    // gets the measured length, not the threshold.
    #expect(stalls(&detector, at: [1, 4.9, 5.4, 6, 600]) == [.seconds(5.4)])
    // The answer reports how long the stall lasted, for the recovery log.
    let stall = detector.replied(at: at(601))
    #expect(stall == .seconds(601))
}

/// The watchdog checks, then pings, once a second. A stall that starts just
/// after an answered ping is caught only by the next ping, 5 s after it, and
/// a late ping tick moves the report one tick later: the requirement says
/// "about 7 s or more".
@Test func aStallJustAfterAnAnswerIsCaughtWithinSevenSeconds() {
    /// The ticks that report the stall when its first ping fires `late`, and
    /// the lengths they report.
    func reports(late: Double) -> [(tick: Int, length: Duration)] {
        var detector = StallDetector(threshold: .seconds(5))
        #expect(ping(&detector, at: 0))
        _ = detector.replied(at: at(0.01)) // the stall starts here
        var reported: [(tick: Int, length: Duration)] = []
        for s in 1...8 {
            if let length = detector.check(at: at(Double(s))) { reported.append((s, length)) }
            let sent = ping(&detector, at: Double(s) + (s == 1 ? late : 0))
            #expect(sent == (s == 1))
        }
        return reported
    }
    let onTime = reports(late: 0)
    #expect(onTime.map(\.tick) == [6])
    // The length counts from the ping at 1 s, not from the start of the stall.
    #expect(onTime.map(\.length) == [.seconds(5)])
    #expect(reports(late: 0.01).map(\.tick) == [7])
}

@Test func answersKeepTheMainThreadHealthy() {
    var detector = StallDetector(threshold: .seconds(5))
    for s in 0..<20 {
        #expect(ping(&detector, at: Double(s)))
        let stall = detector.replied(at: at(Double(s) + 0.01))
        #expect(stall == nil)
        #expect(stalls(&detector, at: [Double(s) + 1]).isEmpty)
    }
}

/// A tick that fires late (App Nap) is not a stall when the main thread
/// answered the last ping at once.
@Test func aLateTickIsNotAStall() {
    var detector = StallDetector(threshold: .seconds(5))
    #expect(ping(&detector, at: 0))
    _ = detector.replied(at: at(0.01))
    #expect(stalls(&detector, at: [10, 60]).isEmpty)
}

/// While a ping is unanswered no other is sent, so a long stall doesn't queue
/// one main-queue block per second.
@Test func oneUnansweredPingAtATime() {
    var detector = StallDetector(threshold: .seconds(5))
    #expect(ping(&detector, at: 0))
    #expect(!ping(&detector, at: 1))
    _ = detector.replied(at: at(1.5))
    #expect(ping(&detector, at: 2))
}

@Test func aLaterStallIsReportedAgain() {
    var detector = StallDetector(threshold: .seconds(5))
    _ = detector.ping(at: t0)
    #expect(stalls(&detector, at: [5]) == [.seconds(5)])
    _ = detector.replied(at: at(7))
    _ = detector.ping(at: at(8))
    #expect(stalls(&detector, at: [12, 13, 14]) == [.seconds(5)])
}

@Test func req_stall_sample_cap() {
    let names = [
        "advisor.log", "advisor.log.1", "notes.txt",
        "hang-3-2026-10-01T09-15-00Z.txt", "hang-10-2026-09-01T08-00-00Z.txt",
        "hang-2-2026-10-31T12-32-22Z.txt",
    ]
    // Newest by sequence number, not by the time in the name: the clock can go back.
    #expect(HangSamples.toDelete(names, keep: 2) == ["hang-2-2026-10-31T12-32-22Z.txt"])
    #expect(HangSamples.toDelete(names, keep: 5).isEmpty)
    let epoch = Date(timeIntervalSince1970: 0)
    #expect(HangSamples.next(after: names, used: 0, at: epoch)
        == (name: "hang-11-1970-01-01T00-00-00Z.txt", number: 11))
    #expect(HangSamples.next(after: ["advisor.log"], used: 0, at: epoch).name
        == "hang-1-1970-01-01T00-00-00Z.txt")
    // A second stall while the first sample is still being written: that file
    // isn't in the folder yet, so the number this run last gave out counts too.
    #expect(HangSamples.next(after: names, used: 11, at: epoch).number == 12)
}
