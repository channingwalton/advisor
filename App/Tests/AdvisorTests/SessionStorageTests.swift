import Testing
import Foundation

@testable import Advisor

// MARK: - config field (issue #16)

@Test func configDecodesMissingSessionDirAsEmpty() throws {
    let config = try JSONDecoder().decode(AdvisorConfig.self, from: Data("{}".utf8))
    #expect(config.sessionDir == "")
}

@Test func configRoundTripsSessionDir() throws {
    var config = AdvisorConfig()
    config.sessionDir = "/Users/me/Transcripts"
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AdvisorConfig.self, from: data)
    #expect(decoded.sessionDir == config.sessionDir)
}

// MARK: - directory resolution

@Test func directoryForBlankReturnsDefault() {
    #expect(SessionArchive.directory(for: "") == SessionArchive.defaultDirectory)
    #expect(SessionArchive.directory(for: "   ") == SessionArchive.defaultDirectory)
}

@Test func directoryForPathReturnsConfiguredFolder() {
    let resolved = SessionArchive.directory(for: "/Users/me/Transcripts")
    #expect(resolved.path == "/Users/me/Transcripts")
    #expect(resolved != SessionArchive.defaultDirectory)
}

// Preferences only ever writes an absolute path, but config.json can be edited
// by hand (code review 2026-10-17): a `~` is the home folder, and a relative
// path — which would otherwise resolve against the app's working directory,
// `/` when packaged — falls back to the default rather than failing every save.
@Test func directoryForTildeExpandsToHome() {
    let resolved = SessionArchive.directory(for: "~/Transcripts")
    #expect(resolved.path == NSHomeDirectory() + "/Transcripts")
}

@Test func directoryForRelativePathFallsBackToDefault() {
    #expect(SessionArchive.directory(for: "Transcripts") == SessionArchive.defaultDirectory)
    #expect(SessionArchive.directory(for: "./notes") == SessionArchive.defaultDirectory)
}

// MARK: - move (relocating transcripts)

/// A throwaway directory holding the given session files, removed on teardown.
private func makeArchive(_ names: [String]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-move-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for name in names {
        try name.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    return dir
}

@Test func moveRelocatesSessionsCreatingDest() throws {
    let source = try makeArchive(["2026-06-18-090000.md", "2026-06-18-170000.md"])
    let dest = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-move-dest-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: dest)
    }

    let result = SessionArchive.move(from: source, to: dest)

    #expect(result == (moved: 2, skipped: 0))
    // dest was created and now holds both notes; source is empty of sessions.
    #expect(SessionArchive.list(in: dest).count == 2)
    #expect(SessionArchive.list(in: source).isEmpty)
}

@Test func moveSkipsCollisionsWithoutClobbering() throws {
    let source = try makeArchive(["2026-06-18-090000.md", "2026-06-18-170000.md"])
    let dest = try makeArchive(["2026-06-18-090000.md"]) // already present
    defer {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: dest)
    }

    let result = SessionArchive.move(from: source, to: dest)

    #expect(result == (moved: 1, skipped: 1))
    // The colliding note is untouched in both places — its dest copy keeps the
    // dest content ("2026-06-18-090000.md"), and the source copy stays put.
    let collidedDest = dest.appendingPathComponent("2026-06-18-090000.md")
    #expect(try String(contentsOf: collidedDest, encoding: .utf8) == "2026-06-18-090000.md")
    #expect(FileManager.default.fileExists(
        atPath: source.appendingPathComponent("2026-06-18-090000.md").path))
    // The non-colliding note did move across.
    #expect(FileManager.default.fileExists(
        atPath: dest.appendingPathComponent("2026-06-18-170000.md").path))
}

@Test func moveSkipsExcludedLiveNote() throws {
    let source = try makeArchive(["2026-06-18-090000.md", "2026-06-18-170000.md"])
    let dest = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-move-dest-\(UUID().uuidString)")
    let live = source.appendingPathComponent("2026-06-18-170000.md")
    defer {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: dest)
    }

    let result = SessionArchive.move(from: source, to: dest, excluding: live)

    #expect(result == (moved: 1, skipped: 0))
    // The live note stays in source; the other moved.
    #expect(FileManager.default.fileExists(atPath: live.path))
    #expect(FileManager.default.fileExists(
        atPath: dest.appendingPathComponent("2026-06-18-090000.md").path))
}

@Test func moveIgnoresNonSessionFiles() throws {
    let source = try makeArchive(["2026-06-18-090000.md", "notes.txt", "README.md"])
    let dest = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-move-dest-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: dest)
    }

    let result = SessionArchive.move(from: source, to: dest)

    #expect(result == (moved: 1, skipped: 0))
    // Non-session files are left behind in source.
    #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("notes.txt").path))
    #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("README.md").path))
}

@Test func moveIsNoOpWhenSourceEqualsDest() throws {
    let dir = try makeArchive(["2026-06-18-090000.md"])
    defer { try? FileManager.default.removeItem(at: dir) }

    let result = SessionArchive.move(from: dir, to: dir)

    #expect(result == (moved: 0, skipped: 0))
    #expect(SessionArchive.list(in: dir).count == 1)
}

// MARK: - writer resolves the folder per session (issue #16, Codex P2)

/// A new session must be written to the *currently* configured folder, resolved
/// at `start()` — not the folder cached when the launch-lifetime writer was
/// created. Otherwise a Preferences folder change wouldn't reach new sessions
/// until an app relaunch.
@MainActor
@Test func writerResolvesFolderAtEachStart() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-writer-test-\(UUID().uuidString)")
    let dirA = base.appendingPathComponent("A")
    let dirB = base.appendingPathComponent("B")
    defer { try? FileManager.default.removeItem(at: base) }

    // A mutable folder the injected resolver reads fresh — stands in for the
    // Preferences setting changing between sessions.
    var current = dirA
    let writer = SessionWriter(store: TranscriptStore(), resolveDirectory: { current })

    writer.start()
    writer.flush()
    #expect(SessionArchive.list(in: dirA).count == 1)
    #expect(SessionArchive.list(in: dirB).isEmpty)
    writer.end()
    writer.releaseNote()

    // Folder changes; the next session must land in B, not the init-time A.
    current = dirB
    writer.start()
    writer.flush()
    #expect(SessionArchive.list(in: dirB).count == 1)
    #expect(SessionArchive.list(in: dirA).count == 1) // the first session stays put
}

// MARK: - recording into a folder (issue #35)

/// Starting a recording with a folder target writes the note into that sub-folder
/// of the archive, so `list` returns it with `folder` set — what a folder's record
/// button in the Sessions sidebar drives.
@MainActor
@Test func writerStartFilesNoteIntoTargetFolder() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-folder-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let writer = SessionWriter(store: TranscriptStore(), resolveDirectory: { base })

    writer.start(folder: "Work")
    writer.flush()

    // The note sits in <base>/Work, not the root, and lists with folder == "Work".
    let inFolder = SessionArchive.list(in: base.appendingPathComponent("Work"))
    #expect(inFolder.count == 1)
    let all = SessionArchive.list(in: base)
    #expect(all.count == 1)
    #expect(all.first?.folder == "Work")
    // Nothing was written to the un-foldered root.
    #expect(!FileManager.default.fileExists(
        atPath: base.appendingPathComponent(inFolder[0].url.lastPathComponent).path))

    writer.end()
    writer.releaseNote()
}

/// A nil or unusable folder target falls back to the un-foldered root, so the
/// global record button (and an empty target) records as before.
@MainActor
@Test func writerStartWithoutFolderWritesToRoot() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-folder-root-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let writer = SessionWriter(store: TranscriptStore(), resolveDirectory: { base })

    writer.start(folder: "  ") // unusable name → root
    writer.flush()

    let all = SessionArchive.list(in: base)
    #expect(all.count == 1)
    #expect(all.first?.folder == nil)

    writer.end()
    writer.releaseNote()
}

// MARK: - live name edit refreshes the Sessions browser

/// A throwaway session folder removed on teardown, for the live-rename tests.
private func makeWriterDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-rename-notify-\(UUID().uuidString)")
}

/// Renaming the live session from the recording toolbar (`updateName` + a
/// debounced write) must tell the Sessions browser to reload, or its sidebar
/// keeps the start-time title. The write that carries the new name posts
/// `.advisorSessionsChanged`.
@MainActor
@Test func liveNameEditRefreshesSessionsBrowser() async throws {
    let dir = makeWriterDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let writer = SessionWriter(store: TranscriptStore(), resolveDirectory: { dir })

    writer.start() // seeds the live note (posts once, before we observe)
    writer.flush()

    await confirmation("Sessions browser reloads after a live rename") { reloaded in
        let token = NotificationCenter.default.addObserver(
            forName: .advisorSessionsChanged, object: nil, queue: nil) { _ in reloaded() }
        defer { NotificationCenter.default.removeObserver(token) }

        writer.updateName("Q3 board review")
        writer.flush() // stands in for the debounced write the toolbar schedules
    }

    let note = try String(contentsOf: SessionArchive.list(in: dir)[0].url, encoding: .utf8)
    #expect(note.contains("name: Q3 board review"))

    writer.end()
    writer.releaseNote()
}

/// A plain content write with no pending name change must not reload the browser —
/// the live note's transcript flows through `noteChanged()` every couple of
/// seconds, and reparsing every saved note that often would thrash the sidebar.
@MainActor
@Test func liveContentWriteWithoutNameChangeDoesNotRefreshBrowser() async throws {
    let dir = makeWriterDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let writer = SessionWriter(store: TranscriptStore(), resolveDirectory: { dir })

    writer.start()
    writer.flush()

    await confirmation(expectedCount: 0) { reloaded in
        let token = NotificationCenter.default.addObserver(
            forName: .advisorSessionsChanged, object: nil, queue: nil) { _ in reloaded() }
        defer { NotificationCenter.default.removeObserver(token) }

        writer.flush() // a content write with no name edit behind it
    }

    writer.end()
    writer.releaseNote()
}
