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

    /// 5 s: a healthy teardown takes the 1.5 s echo delay plus the speech
    /// engines' finalisation, so the margin is for a slow one, not a wedged one.
    init(timeout: Duration = .seconds(5), exit: @escaping () -> Void) {
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
            if await !Self.wait(atMost: timeout, for: shutdown) {
                appLog.write("[advisor] quit: teardown still running after \(timeout) — saving what is there")
            }
            finish()
            exit()
        }
    }

    /// Wait for `work` or the deadline, whichever comes first, cancelling the
    /// other; true when `work` finished. Unstructured tasks, not a task group: a
    /// group waits for every child before it returns, so a hung `work` would
    /// hold it past the deadline.
    private static func wait(atMost timeout: Duration, for work: @escaping @MainActor () async -> Void) async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            var racers: [Task<Void, Never>] = []
            var resumed = false
            let resume: @MainActor (Bool) -> Void = { finished in
                guard !resumed else { return }
                resumed = true
                racers.forEach { $0.cancel() }
                done.resume(returning: finished)
            }
            racers.append(Task { @MainActor in
                await work()
                resume(true)
            })
            racers.append(Task { @MainActor in
                try? await Task.sleep(for: timeout)
                resume(false)
            })
        }
    }
}
