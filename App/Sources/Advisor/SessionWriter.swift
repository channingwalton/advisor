import Foundation

/// Writes each session to an app-managed markdown file (transcripts + cards).
/// The Obsidian vault is never written.
@MainActor
final class SessionWriter {
    let sessionsDirectory: URL
    private let store: TranscriptStore
    private var fileURL: URL?
    private var started: Date?
    private var ended: Date?
    private var pendingWrite: DispatchWorkItem?

    /// The note currently being written (set at session start). The history
    /// browser excludes this while listening so a follow-up append isn't
    /// clobbered by the live rewrite.
    var currentFileURL: URL? { fileURL }

    init(store: TranscriptStore) {
        self.store = store
        sessionsDirectory = SessionArchive.directory
        try? FileManager.default.createDirectory(
            at: sessionsDirectory, withIntermediateDirectories: true)
    }

    func start() {
        started = Date()
        ended = nil
        fileURL = sessionsDirectory.appendingPathComponent(SessionArchive.fileName(for: started!))
        write()
    }

    func end() {
        ended = Date()
        write()
        // fileURL stays set: cards finishing after stop still land in the file.
    }

    /// True when there is something worth exporting — any transcript line, or a
    /// finished card. Drives the toolbar's Export button enabled state.
    var hasExportContent: Bool {
        !store.utterances.isEmpty
            || store.cards.contains { $0.state == "done" || $0.state == "failed" }
    }

    /// Suggested save filename for an export: the on-disk note's name (the
    /// session start time, `yyyy-MM-dd-HHmmss.md`).
    func suggestedFilename() -> String {
        fileURL?.lastPathComponent
            ?? SessionArchive.fileName(for: started ?? store.utterances.first?.time ?? Date())
    }

    /// Copy the current session note to `dest`. Export is just sharing the
    /// transcript: the saved note and the export are byte-identical, so flush
    /// any pending debounced write first, then copy the file (overwriting).
    func export(to dest: URL) throws {
        flush()
        guard let fileURL else { return }
        // Exporting onto the live note itself would delete the source mid-copy.
        guard dest.standardizedFileURL != fileURL.standardizedFileURL else { return }
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: fileURL, to: dest)
    }

    /// Write the note now, cancelling any pending debounced write.
    func flush() {
        pendingWrite?.cancel()
        write()
    }

    /// Debounced rewrite; call whenever utterances or cards change.
    func noteChanged() {
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.write() }
        pendingWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Render the note with cards embedded inline in the conversation (the same
    /// format the window shows). See `SessionMarkdown.inline`.
    private func write() {
        guard let fileURL, let started else { return }
        let md = SessionMarkdown.inline(
            utterances: store.utterances, cards: store.cards, started: started, ended: ended)
        try? md.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
