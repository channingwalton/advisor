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
