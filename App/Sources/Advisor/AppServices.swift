import Foundation

/// Launch-lifetime owner of the services that must outlive any single window:
/// the shared transcript `store`, the `sidecar` agent process, and the session
/// `writer`. These start once at app launch so the Sessions browser can answer
/// questions about saved transcripts before (or without) a recording window
/// ever opening. The `Recorder` (the audio device) is deliberately *not* owned
/// here — it is built on demand by the recording window and only referenced
/// weakly so termination cleanup can still reach it while that window lives.
@MainActor
final class AppServices: ObservableObject {
    let store: TranscriptStore
    let sidecar: SidecarManager
    let writer: SessionWriter
    /// Set by the recording window when it builds its `Recorder`; weak so closing
    /// that window releases the audio device. Read only by termination cleanup.
    weak var recorder: Recorder?

    private var started = false

    init() {
        let store = TranscriptStore()
        self.store = store
        self.sidecar = SidecarManager(store: store)
        self.writer = SessionWriter(store: store)
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
