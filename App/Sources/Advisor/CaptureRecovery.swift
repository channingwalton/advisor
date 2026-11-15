import Foundation

/// A capture source that can stop by itself during a session (issue #135).
enum CaptureSource {
    case microphone
    case systemAudio

    var name: String {
        switch self {
        case .microphone: "microphone"
        case .systemAudio: "system audio"
        }
    }
}

/// A bound on how often a lost capture source is started again. It allows
/// `limit` attempts in any `window` seconds. A source that keeps failing, or
/// keeps stopping after each restart, then stays stopped with a warning.
struct RestartBudget {
    let limit: Int
    let window: TimeInterval
    private var attempts: [Date] = []

    init(limit: Int = 3, window: TimeInterval = 60) {
        self.limit = limit
        self.window = window
    }

    /// Records an attempt at `now` and returns true, or returns false when
    /// the window already holds `limit` attempts.
    mutating func take(at now: Date) -> Bool {
        attempts.removeAll { now.timeIntervalSince($0) >= window }
        guard attempts.count < limit else { return false }
        attempts.append(now)
        return true
    }
}

/// The status-line text for a capture source that stopped by itself.
enum CaptureRecovery {
    static func restartingNote(_ source: CaptureSource) -> String {
        "\(source.name) stopped; restarting…"
    }

    static func restartedNote(_ source: CaptureSource, listening: String) -> String {
        "\(listening) | \(source.name) restarted"
    }

    /// The warning when the source did not start again. `error` is the last
    /// start failure, or nil when the restart bound ran out without one.
    static func failedNote(_ source: CaptureSource, listening: String, error: Error?) -> String {
        let reason: String
        if let error {
            let message = error.localizedDescription
            if source == .systemAudio, SystemAudioCapture.isPermissionFailure(message) {
                reason = SystemAudioCapture.permissionRequiredNote
            } else {
                reason = "\(source.name) stopped and could not restart: \(message)"
            }
        } else {
            reason = "\(source.name) stopped too often to restart; press Stop, then Resume"
        }
        return "\(listening) | \(reason)"
    }
}
