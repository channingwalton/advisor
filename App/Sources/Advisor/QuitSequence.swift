import Foundation

/// What ⌘Q runs (`AppServices`).
@MainActor
protocol Quitting: AnyObject {
    /// The orderly teardown — the recording's speech finals and echo delay
    /// reaching the note. Cut off if it outlasts the quit deadline.
    func shutdown() async
    /// The last step before exiting, run even when `shutdown` was cut off: a
    /// synchronous final save, and stopping the sidecar.
    func finishQuit()
}

/// The ⌘Q teardown: run `shutdown`, then `finish`, then exit — giving up on
/// `shutdown` after `timeout` so a wedged speech engine can't stop the app
/// quitting. Started once; a second ⌘Q while it runs does nothing.
@MainActor
final class QuitSequence {
    private let timeout: Duration
    private let exit: () -> Void
    private var started = false

    init(timeout: Duration = Deadline.recordingTeardown, exit: @escaping () -> Void) {
        self.timeout = timeout
        self.exit = exit
    }

    /// Begin quitting. Returns nil when a quit is already under way.
    @discardableResult
    func start(
        shutdown: @escaping @MainActor () async -> Void,
        finish: @escaping @MainActor () -> Void
    ) -> Task<Void, Never>? {
        guard !started else { return nil }
        started = true
        let timeout = timeout
        let exit = exit
        return Task { @MainActor in
            if await !Deadline.wait(atMost: timeout, for: shutdown) {
                appLog.write("[advisor] quit: teardown still running after \(timeout) — saving what is there")
            }
            finish()
            exit()
        }
    }
}
