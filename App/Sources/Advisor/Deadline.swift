import Foundation

/// A time limit on teardown work that can hang, such as a wedged speech
/// engine. The window close (`AppServices.releaseRecording`) and ⌘Q
/// (`QuitSequence`) use it.
enum Deadline {
    /// 5 s: a healthy teardown takes the 1.5 s echo delay plus the speech
    /// engines' finalisation, so the margin is for a slow one, not a wedged one.
    static let recordingTeardown: Duration = .seconds(5)

    /// Wait for `work` or the deadline, whichever comes first, cancelling the
    /// other; true when `work` finished. Unstructured tasks, not a task group: a
    /// group waits for every child before it returns, so a hung `work` would
    /// hold it past the deadline.
    @MainActor
    static func wait(atMost timeout: Duration, for work: @escaping @MainActor () async -> Void) async -> Bool {
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
