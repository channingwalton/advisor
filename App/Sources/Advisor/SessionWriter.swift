import Foundation

/// Writes each session to an app-managed markdown file (transcripts + cards).
/// The Obsidian vault is never written.
@MainActor
final class SessionWriter {
    /// Resolves the storage folder, called at each `start()` (not cached at
    /// init), so a Preferences change to the session folder (issue #16) reaches
    /// the next session without an app relaunch. Injectable for tests.
    private let resolveDirectory: () -> URL
    private let store: TranscriptStore
    private var fileURL: URL?
    private var started: Date?
    private var ended: Date?
    private var context = ""
    private var name = ""
    private var tags: [String] = []
    /// True between `start()` and `end()`. Gates `updateContext` so a context
    /// change arriving after stop (the toolbar clears the prompt, but
    /// `store.listening` flips asynchronously) can't blank the saved title; late
    /// post-stop rewrites for finishing cards keep the retained context.
    private var sessionActive = false
    private var pendingWrite: DispatchWorkItem?

    /// The note currently being written (set at session start). The history
    /// browser excludes this while listening so a follow-up append isn't
    /// clobbered by the live rewrite.
    var currentFileURL: URL? { fileURL }

    init(
        store: TranscriptStore,
        resolveDirectory: @escaping () -> URL = { SessionArchive.directory }
    ) {
        self.store = store
        self.resolveDirectory = resolveDirectory
    }

    func start(context: String = "", name: String = "", tags: [String] = []) {
        started = Date()
        ended = nil
        self.context = context
        self.name = name
        self.tags = tags
        sessionActive = true
        // Resolve (and create) the storage folder now rather than at init, so a
        // folder changed in Preferences since launch applies to this session.
        let directory = resolveDirectory()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent(SessionArchive.fileName(for: started!))
        write()
        NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
    }

    /// Update the session context mid-session (the prompt is editable while
    /// listening); persisted on the next write so the title stays current.
    /// Ignored once the session has ended — see `sessionActive`.
    func updateContext(_ text: String) {
        guard sessionActive else { return }
        context = text
    }

    /// Update the optional session name mid-session (the name field is editable
    /// while listening); persisted on the next write. Gated on `sessionActive`
    /// like `updateContext`, so the toolbar blanking the field on stop can't wipe
    /// the saved name. `inline` trims/collapses it, so the raw text is fine here.
    func updateName(_ text: String) {
        guard sessionActive else { return }
        name = text
    }

    /// Rename the note this writer still owns (the live or just-finished session,
    /// whose `fileURL` it keeps until the next session starts) and write it out
    /// now. Used by the Sessions browser: a direct frontmatter write would be
    /// clobbered by a late rewrite when a research card finishes, so renaming the
    /// owned note must go through the writer. Not gated — it runs post-stop.
    func renameOwnedNote(_ text: String) {
        name = text
        flush()
    }

    /// Set the tags on the note this writer owns (the live or just-finished
    /// session) and write it out now. Used by the recording toolbar and the
    /// Sessions browser: a direct frontmatter write would be clobbered by a late
    /// rewrite when a research card finishes, so tagging the owned note must go
    /// through the writer. Not gated — it also runs post-stop, like
    /// `renameOwnedNote`.
    func setOwnedNoteTags(_ tags: [String]) {
        self.tags = tags
        flush()
    }

    func end() {
        ended = Date()
        sessionActive = false
        write()
        NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
        // fileURL stays set: cards finishing after stop still land in the file.
    }

    /// Detach from the note this writer owns so no later `write()` can touch it.
    /// Used when the recording window closes and its shared store is cleared for
    /// reuse: the note is already flushed by `end()`, and zeroing `fileURL`/
    /// `started` makes `write()`'s guard no-op any stray rewrite — both the
    /// store-clear's change notification and the app-terminate flush — which would
    /// otherwise serialise the emptied store over the saved note. The next
    /// `start()` re-establishes them.
    func releaseNote() {
        pendingWrite?.cancel()
        fileURL = nil
        started = nil
        ended = nil
        sessionActive = false
    }

    /// True when there is something worth exporting — any transcript line, or a
    /// finished card. Drives the toolbar's Export button enabled state.
    var hasExportContent: Bool {
        !store.utterances.isEmpty
            || !store.notes.isEmpty
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
            utterances: store.utterances, cards: store.cards, notes: store.notes,
            started: started, ended: ended,
            context: context, name: name, tags: tags)
        try? md.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
