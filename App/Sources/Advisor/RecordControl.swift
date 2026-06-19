import Foundation

/// The recording control's three states and the resume timer maths. Stop is
/// resumable (issue #6): stopping tears down audio but leaves the session in
/// progress, so the same note and sidecar classifier session continue when the
/// user resumes. This replaced the removed Pause button — Stop now does what
/// Pause did, only it fully releases the audio engines.
enum RecordControl {
    enum State: Equatable {
        /// No session — the idle "Listen" pill.
        case idle
        /// A session with audio capture running.
        case recording
        /// A session whose audio is stopped but can be resumed.
        case stopped
    }

    /// `listening` is true only while audio is being captured; `stopped` is true
    /// when a resumable session exists with audio torn down. Listening wins: a
    /// brief residue of the stopped flag during start-up still shows recording.
    static func state(listening: Bool, stopped: Bool) -> State {
        if listening { return .recording }
        return stopped ? .stopped : .idle
    }

    /// The session start shifted forward by the just-ended stopped span, so the
    /// elapsed timer counts only time spent recording (matching how the removed
    /// Pause excluded paused spans).
    static func resumedStart(_ sessionStart: Date, stoppedAt: Date, now: Date) -> Date {
        sessionStart.addingTimeInterval(now.timeIntervalSince(stoppedAt))
    }
}
