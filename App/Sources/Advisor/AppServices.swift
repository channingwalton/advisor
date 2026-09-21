import Foundation

/// Launch-lifetime owner of the services that must outlive any single window:
/// the shared transcript `store`, the `sidecar` agent process, and the session
/// `writer`. These start once at app launch so the Sessions browser can answer
/// questions about saved transcripts before (or without) a recording window
/// ever opening. The `Recorder` (the audio device) is deliberately *not* owned
/// here — it is built on demand by the recording window and only referenced
/// weakly so close and termination cleanup can reach it while that window lives.
@MainActor
final class AppServices: ObservableObject {
    let store: TranscriptStore
    let sidecar: SidecarManager
    let writer: SessionWriter
    /// Set by the recording window when it builds its `Recorder`; weak so closing
    /// that window releases the audio device after its queued teardown completes.
    weak var recorder: Recorder?

    @Published private(set) var isClosingRecording = false
    private(set) var recordingCloseTask: Task<Void, Never>?
    private var recordingEndTask: Task<Void, Never>?

    private var started = false

    init(resolveDirectory: @escaping () -> URL = { SessionArchive.directory }) {
        let store = TranscriptStore()
        self.store = store
        self.sidecar = SidecarManager(store: store)
        self.writer = SessionWriter(store: store, resolveDirectory: resolveDirectory)
    }

    /// End capture, retaining ownership while the close guard waits for cards.
    @discardableResult
    func endRecording() -> Task<Void, Never> {
        if let recordingEndTask { return recordingEndTask }
        recorder?.onUtterance = nil
        let stop = recorder?.stop()
        sidecar.sendSessionEnd()
        let task = Task<Void, Never> { @MainActor in
            await stop?.value
            writer.end()
        }
        recordingEndTask = task
        return task
    }

    /// The recording window can disappear before speech teardown completes.
    /// Keep its finalisation alive independently of SwiftUI's cancelled tasks.
    @discardableResult
    func releaseRecording() -> Task<Void, Never> {
        if let recordingCloseTask { return recordingCloseTask }
        isClosingRecording = true
        let end = endRecording()
        let task = Task { @MainActor in
            await end.value
            // Cards may have finished while the close guard waited. Flush them
            // before releasing ownership, then retire the old STT generation.
            writer.flush()
            writer.releaseNote()
            TranscriptWindowContext.shared.liveFileURL = nil
            store.sessionGeneration += 1
            store.utterances = []
            store.cards = []
            store.notes = []
            store.volatile = [:]
            recorder = nil
            recordingEndTask = nil
            recordingCloseTask = nil
            isClosingRecording = false
        }
        recordingCloseTask = task
        return task
    }

    /// Start the sidecar and publish the shared handles the Sessions browser
    /// reads (it observes `TranscriptWindowContext.shared`, not this object).
    /// Idempotent — the launch scene's `.task` may re-run.
    func start(lanes: Int) {
        guard !started else { return }
        started = true
        sidecar.start()
        sidecar.sendLanes(lanes)
        TranscriptWindowContext.shared.sidecar = sidecar
        TranscriptWindowContext.shared.writer = writer
        // Orderly teardown before `_exit(0)` (see AppDelegate). recorder is nil
        // when no recording window is open — that's fine.
        AppDelegate.shared?.onTerminate = { [weak self] in
            self?.recorder?.stop()   // stops audio engine + ScreenCaptureKit stream
            self?.sidecar.stop()     // closes stdin so the node child exits
            self?.writer.end()       // synchronous final flush
        }
    }
}
