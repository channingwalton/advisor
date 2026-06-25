import Foundation

/// Shared handles the past-transcript window needs but can't receive as params:
/// it is a sibling `WindowGroup` scene, not a child of `TranscriptView`, so the
/// live `sidecar` and the note the live writer still owns are passed through a
/// process-wide holder the live view populates and the window observes.
@MainActor
final class TranscriptWindowContext: ObservableObject {
    static let shared = TranscriptWindowContext()

    /// The live sidecar, used to answer questions about a saved transcript.
    /// Set once when the live view sets up; nil before then.
    var sidecar: SidecarManager?

    /// The live session writer, used to rename the note it currently owns (the
    /// live/just-finished session) without racing its debounced rewrite. Renaming
    /// any other saved note goes straight to disk via `SessionArchive.setName`.
    var writer: SessionWriter?

    /// The note the live `SessionWriter` currently owns (from session start until
    /// the next session starts). Asking about it is disabled: the writer's
    /// debounced full rewrite — which still fires post-stop as late research cards
    /// finish — would clobber an appended follow-up.
    @Published var liveFileURL: URL?

    /// The folder a not-yet-started recording should be filed into (issue #35),
    /// set by a folder's record button in the Sessions sidebar before the recording
    /// window opens. The window reads it at session start and clears it; nil means
    /// the next recording is un-foldered (the global record button clears it too).
    @Published var pendingFolder: String?

    private init() {}
}
