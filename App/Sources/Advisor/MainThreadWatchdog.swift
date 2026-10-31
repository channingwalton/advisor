import Foundation

/// Decides when the main thread counts as stalled: a ping unanswered for
/// `threshold`. Measures from the unanswered ping, not from the last answer,
/// so a tick that fires late (App Nap) is not a stall when the main thread
/// answered the last ping at once.
/// Reports each stall once, however long it lasts. Pure — `MainThreadWatchdog`
/// feeds it the times.
struct StallDetector {
    let threshold: Duration
    /// When the unanswered ping was sent; nil when the last one was answered.
    private var pending: SuspendingClock.Instant?
    private var reported = false

    init(threshold: Duration) {
        self.threshold = threshold
    }

    /// Whether to send a ping now. False while one is unanswered, so a long
    /// stall doesn't queue one main-queue block per tick.
    mutating func ping(at now: SuspendingClock.Instant) -> Bool {
        guard pending == nil else { return false }
        pending = now
        return true
    }

    /// The stall so far, on the first check that finds the ping unanswered
    /// for `threshold` or more; nil otherwise.
    mutating func check(at now: SuspendingClock.Instant) -> Duration? {
        guard let pending, !reported, now - pending >= threshold else { return nil }
        reported = true
        return now - pending
    }

    /// Record the answer to the ping. Returns how long the stall lasted when
    /// `check` reported one, so the recovery can be logged too.
    mutating func replied(at now: SuspendingClock.Instant) -> Duration? {
        defer {
            pending = nil
            reported = false
        }
        guard reported, let pending else { return nil }
        return now - pending
    }
}

/// The stack samples kept in the logs folder, named `hang-<n>-<UTC time>.txt`.
/// They are ordered by the sequence number `n`, not the time, because the
/// clock can go back.
enum HangSamples {
    static let keep = 5

    /// The samples to delete so the folder holds the newest `keep`.
    static func toDelete(_ names: [String], keep: Int) -> [String] {
        let samples = names.compactMap { name in number(name).map { (name, $0) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        return Array(samples.dropLast(keep))
    }

    /// The name and number for a new sample: one past the highest number in
    /// `names` and `used`, the last number this run gave out — its file may
    /// not exist yet, as `sample` writes it only when it finishes.
    static func next(after names: [String], used: Int, at date: Date) -> (name: String, number: Int) {
        let n = max(names.compactMap(number).max() ?? 0, used) + 1
        let time = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
        return ("hang-\(n)-\(time).txt", n)
    }

    private static func number(_ name: String) -> Int? {
        guard name.hasPrefix("hang-"), name.hasSuffix(".txt") else { return nil }
        return Int(name.dropFirst("hang-".count).prefix { $0.isNumber })
    }
}

/// Pings the main queue from a background queue every second and, when a
/// ping goes unanswered for `threshold`, logs the stall and saves a `sample`
/// of the process in the logs folder. A hang on close (2026-10-31) left no
/// trace in the log; the sample shows where the main thread is stuck.
/// `SuspendingClock` stops while the Mac sleeps, so a wake is not a stall.
final class MainThreadWatchdog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "advisor.watchdog", qos: .utility)
    private let clock = SuspendingClock()
    private let lock = NSLock()
    private let directory: URL
    private var detector: StallDetector // guarded by `lock`
    private var lastSample = 0 // only used on `queue`
    private var timer: DispatchSourceTimer?

    init(threshold: Duration = .seconds(5), directory: URL) {
        self.directory = directory
        detector = StallDetector(threshold: threshold)
    }

    /// Call once, from the main thread, at launch.
    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        let now = clock.now
        let (stall, send) = lock.withLock { (detector.check(at: now), detector.ping(at: now)) }
        if let stall { sample(after: stall) }
        if send { DispatchQueue.main.async { [weak self] in self?.answer() } }
    }

    private func answer() {
        let now = clock.now
        if let stall = lock.withLock({ detector.replied(at: now) }) {
            appLog.write("[advisor] watchdog: main thread answered again after \(Self.seconds(stall))")
        }
    }

    private func sample(after stall: Duration) {
        let directory = directory
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let next = HangSamples.next(after: existing, used: lastSample, at: Date())
        lastSample = next.number
        let file = directory.appendingPathComponent(next.name)
        appLog.write("[advisor] watchdog: main thread stalled for \(Self.seconds(stall)); sampling to \(file.path)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(getpid()), "3", "-file", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { done in
            appLog.write("[advisor] watchdog: sample exited with status \(done.terminationStatus)")
            // Prune only once the new sample is saved, so a failing `sample`
            // can't delete the old ones one stall at a time.
            guard done.terminationStatus == 0 else { return }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in HangSamples.toDelete(names, keep: HangSamples.keep) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        do {
            try process.run()
        } catch {
            appLog.write("[advisor] watchdog: could not run sample: \(error)")
        }
    }

    private static func seconds(_ d: Duration) -> String {
        let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return String(format: "%.1f s", s)
    }
}
