import Testing
import Foundation

@testable import Advisor

@Test func parsesSessionFilenameDate() {
    #expect(SessionArchive.date(from: "2026-06-18-163953.md") != nil)
    // Non-session names are rejected.
    #expect(SessionArchive.date(from: "notes.md") == nil)
    #expect(SessionArchive.date(from: "README.md") == nil)
    // Right shape, wrong extension.
    #expect(SessionArchive.date(from: "2026-06-18-163953.txt") == nil)
    // Impossible components are rejected (non-lenient parsing).
    #expect(SessionArchive.date(from: "2026-13-99-999999.md") == nil)
}

@Test func filenameDateRoundTrips() throws {
    let name = "2026-06-18-163953.md"
    let date = try #require(SessionArchive.date(from: name))
    // Re-deriving the name from the parsed date reproduces the original.
    #expect(SessionArchive.fileName(for: date) == name)
}

@Test func listsValidSessionsNewestFirst() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-archive-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    for name in ["2026-06-18-090000.md", "2026-06-18-170000.md", "notes.txt", "README.md"] {
        try "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    let files = SessionArchive.list(in: dir)

    // Only the two well-formed session notes; notes.txt and README.md are skipped.
    #expect(files.count == 2)
    #expect(files.first?.url.lastPathComponent == "2026-06-18-170000.md") // newest first
    #expect(files.last?.url.lastPathComponent == "2026-06-18-090000.md")
}

@Test func stripsLeadingYamlFrontmatter() {
    let note = "---\nstarted: 2026-06-18T15:39:53Z\nended: 2026-06-18T15:42:24Z\n---\n\n"
        + "# Transcript\n\n- 16:40:05 hello\n"
    let body = SessionArchive.strippingFrontmatter(note)
    // The metadata block is gone (so markdown can't misread `key:`+`---` as a
    // giant setext heading) and the body starts at the transcript.
    #expect(!body.contains("started:"))
    #expect(!body.contains("ended:"))
    #expect(body.hasPrefix("# Transcript"))
    #expect(body.contains("- 16:40:05 hello"))
}

@Test func leavesContentWithoutFrontmatterUnchanged() {
    let note = "# Transcript\n\n- 16:40 hi\n"
    #expect(SessionArchive.strippingFrontmatter(note) == note)
}

@Test func settingNameInsertsAndPreservesEverythingElse() {
    let note = "---\nstarted: 2026-06-18T17:00:00Z\ncontext: Effects\n---\n\n"
        + "# Transcript\n\n- 17:00:00 hi\n\n# Follow-ups\n\n> **Q · x**\n"
    let out = SessionArchive.settingName("My talk", in: note)
    #expect(SessionArchive.frontmatter(out)["name"] == "My talk")
    #expect(SessionArchive.frontmatter(out)["context"] == "Effects") // other keys kept
    #expect(SessionArchive.strippingFrontmatter(out).hasPrefix("# Transcript"))
    #expect(out.contains("- 17:00:00 hi"))   // body kept
    #expect(out.contains("> **Q · x**"))     // follow-ups kept
}

@Test func settingNameReplacesExisting() {
    let note = "---\nname: Old\nstarted: 2026-06-18T17:00:00Z\n---\n\n# Transcript\n"
    let out = SessionArchive.settingName("New", in: note)
    #expect(SessionArchive.frontmatter(out)["name"] == "New")
    #expect(!out.contains("name: Old"))
}

@Test func settingBlankNameRemovesKey() {
    let note = "---\nname: Old\nstarted: 2026-06-18T17:00:00Z\n---\n\n# Transcript\n"
    let out = SessionArchive.settingName("   ", in: note)
    #expect(SessionArchive.frontmatter(out)["name"] == nil)
    #expect(SessionArchive.frontmatter(out)["started"] == "2026-06-18T17:00:00Z")
}

@Test func settingNameAddsFrontmatterWhenAbsent() {
    let note = "# Transcript\n\n- 17:00 hi\n"
    let out = SessionArchive.settingName("Fresh", in: note)
    #expect(out.hasPrefix("---\nname: Fresh\n---\n\n"))
    #expect(SessionArchive.strippingFrontmatter(out) == note) // body untouched
}

@Test func setNameRoundTripsThroughDisk() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-archive-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let url = dir.appendingPathComponent("2026-06-18-170000.md")
    try "---\ncontext: Effects\n---\n\n# Transcript\n\n- 17:00:00 hi\n"
        .write(to: url, atomically: true, encoding: .utf8)

    let file = try #require(SessionArchive.list(in: dir).first)
    #expect(SessionArchive.setName("Renamed", in: file))

    let parsed = SessionDetail.parse(
        contents: SessionArchive.contents(of: file), fallbackTitle: "x")
    #expect(parsed.name == "Renamed")
    #expect(parsed.title == "Renamed")
    #expect(parsed.context == "Effects") // untouched
}

@Test func deleteRemovesSessionFile() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-archive-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let url = dir.appendingPathComponent("2026-06-18-170000.md")
    try "x".write(to: url, atomically: true, encoding: .utf8)
    let file = try #require(SessionArchive.list(in: dir).first)

    #expect(SessionArchive.delete(file))
    #expect(!FileManager.default.fileExists(atPath: url.path))
    // Deleting an already-gone file reports failure rather than throwing.
    #expect(!SessionArchive.delete(file))
}

@Test func readsContentsOfSessionFile() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-archive-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let url = dir.appendingPathComponent("2026-06-18-170000.md")
    try "# Transcript\n\n- 17:00:00 hello\n".write(to: url, atomically: true, encoding: .utf8)

    let file = try #require(SessionArchive.list(in: dir).first)
    #expect(SessionArchive.contents(of: file).contains("hello"))
}

// MARK: - read/modify/write never resurrects a vanished note (issue #41)

@Test func readContentsReturnsNilForMissingFileButEmptyStringForRealEmpty() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-archive-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let url = dir.appendingPathComponent("2026-06-18-170000.md")
    try "".write(to: url, atomically: true, encoding: .utf8)
    let file = try #require(SessionArchive.list(in: dir).first)

    // A genuinely empty note reads as "" — distinct from a read failure.
    #expect(SessionArchive.readContents(of: file) == "")
    #expect(SessionArchive.contents(of: file) == "")

    try FileManager.default.removeItem(at: url)
    // A missing file reads as nil, not "".
    #expect(SessionArchive.readContents(of: file) == nil)
    #expect(SessionArchive.contents(of: file) == "")
}

/// The four read-modify-write setters must abort — not recreate a stub — when
/// the note has vanished under them (issue #41: silent transcript loss).
@Test func settersDoNotResurrectADeletedNote() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-archive-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let url = dir.appendingPathComponent("2026-06-18-170000.md")

    func withDeletedNote(_ body: (SessionFile) -> Bool) throws {
        try "---\ncontext: Effects\n---\n\n# Transcript\n\n- 17:00:00 hi\n"
            .write(to: url, atomically: true, encoding: .utf8)
        let file = try #require(SessionArchive.list(in: dir).first)
        try FileManager.default.removeItem(at: url) // vanishes before the write
        #expect(body(file) == false)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    try withDeletedNote { SessionArchive.setName("Renamed", in: $0) }
    try withDeletedNote { SessionArchive.setTags(["a", "b"], in: $0) }
    try withDeletedNote { SessionArchive.setTags([], in: $0) } // no zero-byte file
    try withDeletedNote { SessionArchive.upsertSummary("gist", to: $0) }
    try withDeletedNote {
        SessionArchive.appendFollowUp(question: "q", answer: "a", to: $0)
    }
}

// MARK: - folders (issue #25)

/// A throwaway archive holding `root`-level notes and `folders` (name → notes),
/// removed on teardown.
private func makeFolderedArchive(
    root: [String] = [], folders: [String: [String]] = [:]
) throws -> URL {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory
        .appendingPathComponent("advisor-folder-test-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for name in root {
        try "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    for (folder, names) in folders {
        let sub = dir.appendingPathComponent(folder, isDirectory: true)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        for name in names {
            try "x".write(to: sub.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }
    return dir
}

@Test func listTagsEachSessionWithItsFolder() throws {
    let dir = try makeFolderedArchive(
        root: ["2026-06-18-090000.md"],
        folders: ["Work": ["2026-06-18-170000.md"]])
    defer { try? FileManager.default.removeItem(at: dir) }

    let files = SessionArchive.list(in: dir)
    #expect(files.count == 2)
    #expect(files.first { $0.url.lastPathComponent == "2026-06-18-090000.md" }?.folder == nil)
    #expect(files.first { $0.url.lastPathComponent == "2026-06-18-170000.md" }?.folder == "Work")
}

@Test func listIgnoresNonSessionFilesInsideFolders() throws {
    let dir = try makeFolderedArchive(
        folders: ["Work": ["2026-06-18-170000.md", "notes.txt", "README.md"]])
    defer { try? FileManager.default.removeItem(at: dir) }

    let files = SessionArchive.list(in: dir)
    #expect(files.count == 1)
    #expect(files.first?.folder == "Work")
}

@Test func foldersListsSubdirectoriesIncludingEmptyExcludingDotDirs() throws {
    let dir = try makeFolderedArchive(
        root: ["2026-06-18-090000.md"],
        folders: ["Work": ["2026-06-18-170000.md"], "Personal": [], ".hidden": []])
    defer { try? FileManager.default.removeItem(at: dir) }

    // Both real folders (including the empty "Personal"), case-insensitively
    // sorted; the dot-directory and the root note are excluded.
    #expect(SessionArchive.folders(in: dir) == ["Personal", "Work"])
}

@Test func sanitiseFolderNameTrimsAndRejectsUnsafe() {
    #expect(SessionArchive.sanitiseFolderName("  Work  ") == "Work")
    #expect(SessionArchive.sanitiseFolderName("") == nil)
    #expect(SessionArchive.sanitiseFolderName("   ") == nil)
    #expect(SessionArchive.sanitiseFolderName("a/b") == nil)
    #expect(SessionArchive.sanitiseFolderName("a:b") == nil)
    #expect(SessionArchive.sanitiseFolderName(".hidden") == nil)
    #expect(SessionArchive.sanitiseFolderName("..") == nil)
}

@Test func createFolderCreatesDirectoryAndIsIdempotent() throws {
    let dir = try makeFolderedArchive()
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(SessionArchive.createFolder("Work", in: dir))
    #expect(SessionArchive.folders(in: dir) == ["Work"])
    // Creating it again succeeds; an unusable name is rejected.
    #expect(SessionArchive.createFolder("Work", in: dir))
    #expect(!SessionArchive.createFolder("a/b", in: dir))
    #expect(SessionArchive.folders(in: dir) == ["Work"])
}

@Test func setFolderMovesNoteIntoSubdirAndBackToRoot() throws {
    let dir = try makeFolderedArchive(root: ["2026-06-18-170000.md"])
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = try #require(SessionArchive.list(in: dir).first)
    let filed = try #require(SessionArchive.setFolder("Work", for: file, root: dir))
    #expect(filed.folder == "Work")
    #expect(filed.url == dir.appendingPathComponent("Work/2026-06-18-170000.md"))
    #expect(FileManager.default.fileExists(atPath: filed.url.path))
    #expect(!FileManager.default.fileExists(atPath: file.url.path)) // moved, not copied

    let unfiled = try #require(SessionArchive.setFolder(nil, for: filed, root: dir))
    #expect(unfiled.folder == nil)
    #expect(unfiled.url == dir.appendingPathComponent("2026-06-18-170000.md"))
    #expect(SessionArchive.list(in: dir).first?.folder == nil)
}

@Test func setFolderNeverClobbersExistingNote() throws {
    let dir = try makeFolderedArchive(
        root: ["2026-06-18-170000.md"],
        folders: ["Work": ["2026-06-18-170000.md"]])
    defer { try? FileManager.default.removeItem(at: dir) }

    let rootFile = try #require(
        SessionArchive.list(in: dir).first { $0.folder == nil })
    // A same-named note already sits in Work → the move is refused, source kept.
    #expect(SessionArchive.setFolder("Work", for: rootFile, root: dir) == nil)
    #expect(FileManager.default.fileExists(atPath: rootFile.url.path))
}

@Test func setFolderRejectsInvalidName() throws {
    let dir = try makeFolderedArchive(root: ["2026-06-18-170000.md"])
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = try #require(SessionArchive.list(in: dir).first)
    #expect(SessionArchive.setFolder("bad/name", for: file, root: dir) == nil)
    #expect(FileManager.default.fileExists(atPath: file.url.path)) // untouched
}

@Test func renameFolderMovesDirectoryWithItsNotes() throws {
    let dir = try makeFolderedArchive(folders: ["Work": ["2026-06-18-170000.md"]])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(SessionArchive.renameFolder(from: "Work", to: "Projects", in: dir))
    #expect(SessionArchive.folders(in: dir) == ["Projects"])
    #expect(SessionArchive.list(in: dir).first?.folder == "Projects")
}

@Test func renameFolderRejectsCollisionWithDifferentFolder() throws {
    let dir = try makeFolderedArchive(
        folders: ["Work": ["2026-06-18-170000.md"], "Personal": []])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(!SessionArchive.renameFolder(from: "Work", to: "Personal", in: dir))
    #expect(SessionArchive.folders(in: dir) == ["Personal", "Work"]) // unchanged
}

@Test func deleteFolderUnfilesSessionsAndRemovesDirectory() throws {
    let dir = try makeFolderedArchive(folders: ["Work": ["2026-06-18-170000.md"]])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(SessionArchive.deleteFolder("Work", in: dir))
    #expect(SessionArchive.folders(in: dir).isEmpty) // directory gone
    let files = SessionArchive.list(in: dir)
    #expect(files.count == 1) // session preserved, not deleted
    #expect(files.first?.folder == nil) // un-filed back to root
}

@Test func deleteFolderPreservesSessionThatCannotBeUnfiled() throws {
    // A same-named note already sits in root, so the folder's note can't move
    // back without clobbering it. The session must survive and the folder stay.
    let dir = try makeFolderedArchive(
        root: ["2026-06-18-170000.md"],
        folders: ["Work": ["2026-06-18-170000.md"]])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(!SessionArchive.deleteFolder("Work", in: dir)) // not removed
    #expect(SessionArchive.folders(in: dir) == ["Work"])   // folder kept
    // Both notes still exist: the root original and the un-movable foldered one.
    let files = SessionArchive.list(in: dir)
    #expect(files.count == 2)
    #expect(files.contains { $0.folder == "Work" })
}

@Test func renameFolderRejectsUnsafeSourceName() throws {
    // Defence-in-depth (issue #62): a traversing `from` must be rejected, not
    // used to move a directory that lives outside the archive into it.
    let fm = FileManager.default
    let base = fm.temporaryDirectory
        .appendingPathComponent("advisor-folder-escape-\(UUID().uuidString)")
    let archive = base.appendingPathComponent("archive", isDirectory: true)
    let secret = base.appendingPathComponent("secret", isDirectory: true)
    try fm.createDirectory(at: archive, withIntermediateDirectories: true)
    try fm.createDirectory(at: secret, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }

    #expect(!SessionArchive.renameFolder(from: "../secret", to: "Pulled", in: archive))
    #expect(fm.fileExists(atPath: secret.path))                                    // untouched
    #expect(!fm.fileExists(atPath: archive.appendingPathComponent("Pulled").path)) // nothing pulled in
}

@Test func deleteFolderRejectsUnsafeName() throws {
    // Defence-in-depth (issue #62): a traversing name must be rejected, not used
    // to un-file/remove a directory outside the archive.
    let fm = FileManager.default
    let base = fm.temporaryDirectory
        .appendingPathComponent("advisor-folder-escape-\(UUID().uuidString)")
    let archive = base.appendingPathComponent("archive", isDirectory: true)
    let secret = base.appendingPathComponent("secret", isDirectory: true)
    try fm.createDirectory(at: archive, withIntermediateDirectories: true)
    try fm.createDirectory(at: secret, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }

    #expect(!SessionArchive.deleteFolder("../secret", in: archive))
    #expect(fm.fileExists(atPath: secret.path)) // external dir untouched
}

@Test func setFolderIntoCurrentFolderIsANoOp() throws {
    let dir = try makeFolderedArchive(folders: ["Work": ["2026-06-18-170000.md"]])
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = try #require(SessionArchive.list(in: dir).first)
    let same = try #require(SessionArchive.setFolder("Work", for: file, root: dir))
    #expect(same.url == file.url)
    #expect(same.folder == "Work")
    #expect(FileManager.default.fileExists(atPath: file.url.path))
}

@Test func moveRelocationPreservesFolderStructure() throws {
    let source = try makeFolderedArchive(
        root: ["2026-06-18-090000.md"],
        folders: ["Work": ["2026-06-18-170000.md"]])
    let dest = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-folder-dest-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: dest)
    }

    let result = SessionArchive.move(from: source, to: dest)
    #expect(result == (moved: 2, skipped: 0))
    let moved = SessionArchive.list(in: dest)
    #expect(moved.first { $0.url.lastPathComponent == "2026-06-18-090000.md" }?.folder == nil)
    #expect(moved.first { $0.url.lastPathComponent == "2026-06-18-170000.md" }?.folder == "Work")
    #expect(SessionArchive.folders(in: dest) == ["Work"])
}

// MARK: - Folder context (issue #36)

@Test func folderContextRoundTripsAndIsInvisibleToListing() throws {
    let dir = try makeFolderedArchive(folders: ["Work": ["2026-06-18-170000.md"]])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(SessionArchive.folderContext("Work", root: dir).isEmpty) // unset → ""
    #expect(SessionArchive.setFolderContext("  Quarterly review with Sam  ", for: "Work", root: dir))
    #expect(SessionArchive.folderContext("Work", root: dir) == "Quarterly review with Sam")
    // The hidden context file must not surface as a session or shift the folder list.
    #expect(SessionArchive.list(in: dir).count == 1)
    #expect(SessionArchive.folders(in: dir) == ["Work"])
}

@Test func setFolderContextCreatesFolderDirectory() throws {
    let dir = try makeFolderedArchive()
    defer { try? FileManager.default.removeItem(at: dir) }

    // Saving context for a folder with no directory yet creates it.
    #expect(SessionArchive.setFolderContext("Standup", for: "Daily", root: dir))
    #expect(SessionArchive.folders(in: dir) == ["Daily"])
    #expect(SessionArchive.folderContext("Daily", root: dir) == "Standup")
}

@Test func setFolderContextWithBlankRemovesFile() throws {
    let dir = try makeFolderedArchive(folders: ["Work": []])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(SessionArchive.setFolderContext("temp", for: "Work", root: dir))
    #expect(SessionArchive.setFolderContext("   ", for: "Work", root: dir)) // clears
    #expect(SessionArchive.folderContext("Work", root: dir).isEmpty)
    let ctxURL = try #require(SessionArchive.folderContextURL("Work", root: dir))
    #expect(!FileManager.default.fileExists(atPath: ctxURL.path))
}

@Test func setFolderContextRejectsUnsafeName() throws {
    let dir = try makeFolderedArchive()
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(!SessionArchive.setFolderContext("x", for: "a/b", root: dir))
    #expect(SessionArchive.folderContextURL("a/b", root: dir) == nil)
    #expect(SessionArchive.folderContext("a/b", root: dir).isEmpty)
}

@Test func renameFolderCarriesContext() throws {
    let dir = try makeFolderedArchive(folders: ["Work": []])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(SessionArchive.setFolderContext("Roadmap chats", for: "Work", root: dir))
    #expect(SessionArchive.renameFolder(from: "Work", to: "Projects", in: dir))
    #expect(SessionArchive.folderContext("Projects", root: dir) == "Roadmap chats")
    #expect(SessionArchive.folderContext("Work", root: dir).isEmpty)
}

@Test func deleteFolderRemovesContextFileAndDirectory() throws {
    let dir = try makeFolderedArchive(folders: ["Work": ["2026-06-18-170000.md"]])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(SessionArchive.setFolderContext("Notes", for: "Work", root: dir))
    // The lingering hidden context file must not block the empty-folder removal.
    #expect(SessionArchive.deleteFolder("Work", in: dir))
    #expect(SessionArchive.folders(in: dir).isEmpty)
    #expect(SessionArchive.list(in: dir).first?.folder == nil) // session un-filed, kept
}

@Test func deleteFolderPreservesContextWhenDeletionAborts() throws {
    // A same-named note in root blocks un-filing, so the folder is kept; its
    // context must survive too rather than being destroyed by a no-op delete.
    let dir = try makeFolderedArchive(
        root: ["2026-06-18-170000.md"],
        folders: ["Work": ["2026-06-18-170000.md"]])
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(SessionArchive.setFolderContext("Keep me", for: "Work", root: dir))

    #expect(!SessionArchive.deleteFolder("Work", in: dir)) // aborted, folder kept
    #expect(SessionArchive.folders(in: dir) == ["Work"])
    #expect(SessionArchive.folderContext("Work", root: dir) == "Keep me") // not destroyed
}

@Test func moveCarriesFolderContext() throws {
    let source = try makeFolderedArchive(folders: ["Work": ["2026-06-18-170000.md"]])
    let dest = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-folder-ctx-dest-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: dest)
    }
    #expect(SessionArchive.setFolderContext("Carried over", for: "Work", root: source))

    _ = SessionArchive.move(from: source, to: dest)
    #expect(SessionArchive.folderContext("Work", root: dest) == "Carried over")
}

// MARK: - Folder tags (issue #76)

@Test func folderTagsRoundTripAndAreInvisibleToListing() throws {
    let dir = try makeFolderedArchive(folders: ["Work": ["2026-06-18-170000.md"]])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(SessionArchive.folderTags("Work", root: dir).isEmpty)
    #expect(SessionArchive.setFolderTags(
        [" Work ", "urgent", "work", "a,b\nc"], for: "Work", root: dir))
    #expect(SessionArchive.folderTags("Work", root: dir) == ["Work", "urgent", "a b c"])
    #expect(SessionArchive.list(in: dir).count == 1)
    #expect(SessionArchive.folders(in: dir) == ["Work"])
}

@Test func setFolderTagsWithEmptyListRemovesFile() throws {
    let dir = try makeFolderedArchive(folders: ["Work": []])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(SessionArchive.setFolderTags(["work"], for: "Work", root: dir))
    #expect(SessionArchive.setFolderTags([], for: "Work", root: dir))
    #expect(SessionArchive.folderTags("Work", root: dir).isEmpty)
    let tagsURL = try #require(SessionArchive.folderTagsURL("Work", root: dir))
    #expect(!FileManager.default.fileExists(atPath: tagsURL.path))
}

@Test func setFolderTagsRejectsUnsafeName() throws {
    let dir = try makeFolderedArchive()
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(!SessionArchive.setFolderTags(["work"], for: "a/b", root: dir))
    #expect(SessionArchive.folderTagsURL("a/b", root: dir) == nil)
    #expect(SessionArchive.folderTags("a/b", root: dir).isEmpty)
}

@Test func setFolderTagsReportsWriteFailure() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-folder-tags-blocked-\(UUID().uuidString)")
    try "not a directory".write(to: root, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(!SessionArchive.setFolderTags(["work"], for: "Team", root: root))
}

@Test func renameFolderCarriesTags() throws {
    let dir = try makeFolderedArchive(folders: ["Work": []])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(SessionArchive.setFolderTags(["work", "urgent"], for: "Work", root: dir))
    #expect(SessionArchive.renameFolder(from: "Work", to: "Projects", in: dir))
    #expect(SessionArchive.folderTags("Projects", root: dir) == ["work", "urgent"])
    #expect(SessionArchive.folderTags("Work", root: dir).isEmpty)
}

@Test func deleteFolderRemovesTagsFileAndDirectory() throws {
    let dir = try makeFolderedArchive(folders: ["Work": ["2026-06-18-170000.md"]])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(SessionArchive.setFolderTags(["work"], for: "Work", root: dir))
    #expect(SessionArchive.deleteFolder("Work", in: dir))
    #expect(SessionArchive.folders(in: dir).isEmpty)
    #expect(SessionArchive.list(in: dir).first?.folder == nil)
}

@Test func deleteFolderPreservesTagsWhenDeletionAborts() throws {
    let dir = try makeFolderedArchive(
        root: ["2026-06-18-170000.md"],
        folders: ["Work": ["2026-06-18-170000.md"]])
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(SessionArchive.setFolderTags(["keep-me"], for: "Work", root: dir))

    #expect(!SessionArchive.deleteFolder("Work", in: dir))
    #expect(SessionArchive.folderTags("Work", root: dir) == ["keep-me"])
}

@Test func moveCarriesFolderTags() throws {
    let source = try makeFolderedArchive(folders: ["Work": ["2026-06-18-170000.md"]])
    let dest = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-folder-tags-dest-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: dest)
    }
    #expect(SessionArchive.setFolderTags(["work", "urgent"], for: "Work", root: source))

    _ = SessionArchive.move(from: source, to: dest)
    #expect(SessionArchive.folderTags("Work", root: dest) == ["work", "urgent"])
}

@MainActor
@Test func folderRecordingDefaultsSeedTheWriterOnlyBeforeStart() throws {
    let dir = try makeFolderedArchive(folders: ["Work": []])
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(SessionArchive.setFolderContext("Team sync", for: "Work", root: dir))
    #expect(SessionArchive.setFolderTags(
        ["work", "deleted", "urgent"], for: "Work", root: dir))

    let library = [
        SavedTag(name: "work", colorHex: "0x000000"),
        SavedTag(name: "urgent", colorHex: "0x000000"),
    ]
    var draft = RecordingDraft(context: "manual", tags: ["manual"])
    let seeded = draft.seedFromFolder(
        pendingFolder: "Work", sessionActive: false,
        library: library, root: dir)
    #expect(seeded)
    #expect(draft == RecordingDraft(context: "Team sync", tags: ["work", "urgent"]))

    let writer = SessionWriter(store: TranscriptStore(), resolveDirectory: { dir })
    writer.start(context: draft.context, tags: draft.tags, folder: "Work")
    writer.flush()
    let note = try #require(SessionArchive.list(in: dir).first)
    let detail = SessionDetail.parse(
        contents: SessionArchive.contents(of: note), fallbackTitle: "x")
    #expect(detail.context == "Team sync")
    #expect(detail.tags == ["work", "urgent"])

    var unchanged = RecordingDraft(context: "manual", tags: ["manual"])
    let noFolder = unchanged.seedFromFolder(
        pendingFolder: nil, sessionActive: false, library: library, root: dir)
    let alreadyActive = unchanged.seedFromFolder(
        pendingFolder: "Work", sessionActive: true, library: library, root: dir)
    #expect(!noFolder)
    #expect(!alreadyActive)
    #expect(unchanged == RecordingDraft(context: "manual", tags: ["manual"]))
}

@Test func recordingDraftDropsDeletedTagsBeforeSessionStart() {
    var draft = RecordingDraft(context: "Team sync", tags: ["work", "deleted", "urgent"])
    draft.retainKnownTags(in: [
        SavedTag(name: "work", colorHex: "0x000000"),
        SavedTag(name: "urgent", colorHex: "0x000000"),
    ])

    #expect(draft == RecordingDraft(context: "Team sync", tags: ["work", "urgent"]))
}

@Test func aMovedNoteIsFoundAgainByItsFileName() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-archive-test-\(UUID().uuidString)")
    let folder = dir.appendingPathComponent("Work")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let name = "2026-06-18-090000.md"
    let date = try #require(SessionArchive.date(from: name))
    let original = SessionFile(url: dir.appendingPathComponent(name), date: date, folder: nil)
    try "x".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)

    let moved = SessionArchive.relocated(original, in: dir)
    #expect(moved?.folder == "Work")
    #expect(moved?.url.lastPathComponent == name)
    try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    #expect(SessionArchive.relocated(original, in: dir) == nil)
}
