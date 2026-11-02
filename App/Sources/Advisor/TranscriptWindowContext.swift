import Foundation

/// The context and known-library tags inherited by a recording targeted at a
/// folder (issues #36/#76). Kept as a pure loader so the pre-session gating and
/// complete seed are regression-testable outside SwiftUI.
struct FolderRecordingDefaults: Equatable {
    let context: String
    let tags: [String]

    static func load(
        pendingFolder: String?,
        sessionActive: Bool,
        library: [SavedTag],
        root: URL = SessionArchive.directory
    ) -> FolderRecordingDefaults? {
        guard !sessionActive, let folder = pendingFolder else { return nil }
        let tags = SessionArchive.folderTags(folder, root: root).filter {
            TagLibrary.named($0, in: library) != nil
        }
        return FolderRecordingDefaults(
            context: SessionArchive.folderContext(folder, root: root),
            tags: tags)
    }
}

/// The editable pre/live-session values that folder defaults seed and
/// `SessionWriter.start` consumes. Keeping them together makes the inheritance
/// mutation testable as recording state, not only as an archive read.
struct RecordingDraft: Equatable {
    var context = ""
    var tags: [String] = []

    @discardableResult
    mutating func seedFromFolder(
        pendingFolder: String?,
        sessionActive: Bool,
        library: [SavedTag],
        root: URL = SessionArchive.directory
    ) -> Bool {
        guard let defaults = FolderRecordingDefaults.load(
            pendingFolder: pendingFolder,
            sessionActive: sessionActive,
            library: library,
            root: root)
        else { return false }
        context = defaults.context
        tags = defaults.tags
        return true
    }

    /// Drop defaults whose library entries were deleted while the recording
    /// window was open but not yet started. Live sessions deliberately keep their
    /// note tags, matching existing session-tag deletion semantics.
    mutating func retainKnownTags(in library: [SavedTag]) {
        tags = tags.filter { TagLibrary.named($0, in: library) != nil }
    }
}

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
    /// finish — would clobber an appended follow-up. Compare a note with it
    /// through `SessionArchive.isSameNote`, not `==` (issue #114).
    @Published var liveFileURL: URL?

    /// The folder a not-yet-started recording should be filed into (issue #35),
    /// set by a folder's record button in the Sessions sidebar before the recording
    /// window opens. The window reads it at session start and clears it; nil means
    /// the next recording is un-foldered (the global record button clears it too).
    @Published var pendingFolder: String?

    private init() {}
}
