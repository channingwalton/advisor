import Foundation

/// When to write the session note after a change (#141). The write waits for a
/// quiet period after the last change, but never longer than a maximum after
/// the first change that is not yet written. The time is an input, so a test
/// needs no real waits.
struct WriteDebounce {
    var quiet: Duration = .seconds(2)
    var maximum: Duration = .seconds(10)

    /// The time of the first change since the last write; nil when none is pending.
    private var firstChange: SuspendingClock.Instant?

    /// How long to wait before writing, for a change at `now`.
    mutating func delay(forChangeAt now: SuspendingClock.Instant) -> Duration {
        let first = firstChange ?? now
        firstChange = first
        let left = maximum - (now - first)
        return max(.zero, min(quiet, left))
    }

    /// Call when the note is written, so the next change starts a new maximum.
    mutating func written() {
        firstChange = nil
    }
}
