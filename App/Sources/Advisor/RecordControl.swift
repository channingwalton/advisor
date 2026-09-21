import Foundation
import Combine

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

/// Owns the recording view's start/stop/resume action and timer state. The
/// toolbar and Space shortcut share this state and the same lifecycle handles.
@MainActor
final class RecordingControl: ObservableObject {
    @Published private(set) var sessionStart: Date?
    @Published private(set) var stoppedAt: Date?
    @Published private(set) var isStarting = false
    private let store: TranscriptStore
    private var startTask: Task<Void, Never>?
    private var startID: UUID?
    private var listeningObservation: AnyCancellable?

    init(store: TranscriptStore) {
        self.store = store
        listeningObservation = store.$listening.removeDuplicates().sink { [weak self] listening in
            guard let self, !listening, sessionStart != nil, !isStarting else { return }
            // Includes an automatic STT recovery that ultimately stopped capture.
            // Preserve the note and expose the same Resume action as manual Stop.
            stoppedAt = stoppedAt ?? Date()
        }
    }

    var state: RecordControl.State {
        RecordControl.state(listening: store.listening, stopped: stoppedAt != nil)
    }

    @discardableResult
    func start(recorder: Recorder, device: InputDevice?, captureSystem: Bool) -> Task<Void, Never>? {
        guard sessionStart == nil else { return nil }
        sessionStart = Date()
        stoppedAt = nil
        return startAudio(recorder: recorder, device: device, captureSystem: captureSystem)
    }

    func stop(recorder: Recorder) {
        guard store.listening else { return }
        stoppedAt = Date()
        recorder.stop()
    }

    @discardableResult
    func resume(recorder: Recorder, device: InputDevice?, captureSystem: Bool) -> Task<Void, Never>? {
        guard sessionStart != nil, stoppedAt != nil, !store.listening, !isStarting else { return nil }
        return startAudio(recorder: recorder, device: device, captureSystem: captureSystem)
    }

    func cancelStart() {
        startTask?.cancel()
        startTask = nil
        startID = nil
        isStarting = false
    }

    func end() {
        cancelStart()
        sessionStart = nil
        stoppedAt = nil
    }

    private func startAudio(
        recorder: Recorder, device: InputDevice?, captureSystem: Bool
    ) -> Task<Void, Never> {
        isStarting = true
        let id = UUID()
        startID = id
        let operation = recorder.start(device: device, captureSystem: captureSystem)
        startTask = operation
        return Task { @MainActor in
            await operation.value
            guard startID == id else { return }
            startTask = nil
            startID = nil
            if store.listening, let start = sessionStart, let stoppedAt {
                sessionStart = RecordControl.resumedStart(start, stoppedAt: stoppedAt, now: Date())
                self.stoppedAt = nil
            } else if !store.listening, sessionStart != nil {
                // Initial failures never transition listening from true to false,
                // so they need reconciliation when the start operation finishes.
                stoppedAt = stoppedAt ?? Date()
            }
            isStarting = false
        }
    }
}
