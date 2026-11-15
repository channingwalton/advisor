import Foundation
import Testing

@testable import Advisor

// #141: the note write waits 2 s after the last change, but never more than
// 10 s after the first change that is not yet written.

private let t0 = SuspendingClock().now

private func at(_ seconds: Double) -> SuspendingClock.Instant { t0 + .seconds(seconds) }

@Test func aSingleChangeWaitsTheQuietPeriod() {
    var d = WriteDebounce()
    #expect(d.delay(forChangeAt: at(0)) == .seconds(2))
}

@Test func eachChangeRestartsTheQuietPeriod() {
    var d = WriteDebounce()
    _ = d.delay(forChangeAt: at(0))
    #expect(d.delay(forChangeAt: at(1.5)) == .seconds(2))
    #expect(d.delay(forChangeAt: at(3)) == .seconds(2))
}

@Test func theWaitShrinksToTheMaximumFromTheFirstChange() {
    var d = WriteDebounce()
    _ = d.delay(forChangeAt: at(0))
    for s in stride(from: 1.0, through: 8.0, by: 1.0) { _ = d.delay(forChangeAt: at(s)) }
    // 9 s in: 1 s of the 10 s left, less than the 2 s quiet period.
    #expect(d.delay(forChangeAt: at(9)) == .seconds(1))
}

@Test func aChangePastTheMaximumWritesAtOnce() {
    var d = WriteDebounce()
    _ = d.delay(forChangeAt: at(0))
    #expect(d.delay(forChangeAt: at(10)) == .zero)
    #expect(d.delay(forChangeAt: at(12)) == .zero)
}

@Test func aWriteStartsTheMaximumAgain() {
    var d = WriteDebounce()
    _ = d.delay(forChangeAt: at(0))
    d.written()
    #expect(d.delay(forChangeAt: at(20)) == .seconds(2))
    #expect(d.delay(forChangeAt: at(21)) == .seconds(2))
}
