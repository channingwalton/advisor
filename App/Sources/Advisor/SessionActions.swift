import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Session actions (shared by the browser list's context menu and the
// detail pane's ellipsis menu, so their live-note handling can't diverge).

/// Live-note-aware rename: routes through the recording writer when `file` is the
/// note being recorded right now (so its next debounced rewrite carries the new
/// name), else edits the saved note on disk. Posts `advisorSessionsChanged` so the
/// browser reloads from disk. The live note is only ever renamed through its
/// writer: with none published the rename is refused (issue #85) — a direct
/// frontmatter write would be undone by the writer's next debounced rewrite, so
/// it would save and then silently vanish. DESIGN.md (#85) has why the app never
/// reaches the refusal today.
@MainActor func renameSession(_ file: SessionFile, to name: String, ctx: TranscriptWindowContext) {
    let new = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if SessionArchive.isSameNote(file.url, ctx.liveFileURL) {
        guard let writer = ctx.writer else { return }
        writer.renameOwnedNote(new)
    } else {
        SessionArchive.setName(new, in: file)
    }
    NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
}

/// Delete a saved note from disk and reload the browser. The live note is never
/// passed here — both menus disable its Delete entry — because its writer would
/// just recreate the file.
@MainActor func deleteSession(_ file: SessionFile) {
    SessionArchive.delete(file)
    NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
}

/// Open a session note in the app that macOS uses for Markdown files (issue
/// #127). The live note is never passed here — both menus disable its entry —
/// because the writer rewrites it until it releases the note (after the late
/// cards, at the close of the recording window), and an editor that saves an
/// old copy after the last rewrite drops the lines added since. The
/// workspace returns `false` with no message of its own (a note deleted in
/// Finder, for example), so a failure goes to `reportFailure`.
@MainActor func openSessionInDefaultApp(
    _ file: SessionFile,
    open: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
    reportFailure: @MainActor (URL) -> Void = showOpenFailure
) {
    if !open(file.url) { reportFailure(file.url) }
}

/// The modal alert for an open that failed.
@MainActor func showOpenFailure(_ url: URL) {
    let alert = NSAlert()
    alert.messageText = "Couldn't open the session"
    alert.informativeText =
        "No app opened \(url.lastPathComponent). The file may have moved or been deleted."
    alert.runModal()
}

/// Copy a session note to a user-chosen destination. Atomic write (read source,
/// then replace) never pre-deletes the destination, so a failure can't leave a
/// chosen file gone, and exporting onto the source itself is harmless. Failures
/// surface as a modal alert.
@MainActor func exportSessionCopy(_ file: SessionFile) {
    guard let dest = exportDestination(suggestedName: file.url.lastPathComponent) else { return }
    do {
        try Data(contentsOf: file.url).write(to: dest, options: .atomic)
    } catch {
        let alert = NSAlert()
        alert.messageText = "Export failed"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

/// The save panel both exports share — the recording window's (`TranscriptView
/// .exportSession`, via the writer) and the browser's (`exportSessionCopy`): a
/// Markdown file under `suggestedName`, or nil when cancelled. One panel, so the
/// two cannot drift (they had: only one offered the `.md` type).
@MainActor func exportDestination(suggestedName: String) -> URL? {
    let panel = NSSavePanel()
    panel.title = "Export Session"
    panel.nameFieldStringValue = suggestedName
    // Markdown when the system knows the type; otherwise any (never a `.txt` suffix).
    panel.allowedContentTypes = [UTType(filenameExtension: "md")].compactMap { $0 }
    panel.canCreateDirectories = true
    return panel.runModal() == .OK ? panel.url : nil
}
