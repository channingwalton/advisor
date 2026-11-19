import Foundation
import Testing

@testable import Advisor

// MARK: - Nested session folders (issue #155)

/// A throwaway archive with `notes` (relative paths such as `Work/Client/x.md`)
/// and empty `folders` (relative paths). Remove it on teardown.
private func makeNestedArchive(notes: [String] = [], folders: [String] = []) throws -> URL {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("advisor-nested-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for folder in folders {
        try fm.createDirectory(
            at: dir.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true)
    }
    for note in notes {
        let url = dir.appendingPathComponent(note)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: url, atomically: true, encoding: .utf8)
    }
    return dir
}

@Test func sanitiseFolderPathChecksEachName() {
    #expect(SessionArchive.sanitiseFolderPath("Work/Client A") == "Work/Client A")
    #expect(SessionArchive.sanitiseFolderPath("Work") == "Work")
    // A path names folders on disk exactly: a space or a `:` (Finder's `/`)
    // stays, so `Work ` names `Work `, not `Work`.
    #expect(SessionArchive.sanitiseFolderPath(" Work / Client A ") == " Work / Client A ")
    #expect(SessionArchive.sanitiseFolderPath("Work ") == "Work ")
    #expect(SessionArchive.sanitiseFolderPath("Work/a:b") == "Work/a:b")
    #expect(SessionArchive.sanitiseFolderPath("") == nil)
    #expect(SessionArchive.sanitiseFolderPath("  ") == nil)
    #expect(SessionArchive.sanitiseFolderPath("Work/ ") == nil)
    #expect(SessionArchive.sanitiseFolderPath("Work//A") == nil)
    #expect(SessionArchive.sanitiseFolderPath("/Work") == nil)
    #expect(SessionArchive.sanitiseFolderPath("Work/") == nil)
    #expect(SessionArchive.sanitiseFolderPath("Work/../secret") == nil)
    #expect(SessionArchive.sanitiseFolderPath("../secret") == nil)
    #expect(SessionArchive.sanitiseFolderPath("Work/.hidden") == nil)
}

@Test func folderPathPartsNameTheParentAndTheLastName() {
    #expect(SessionArchive.parentFolder("Work/Client A/2026") == "Work/Client A")
    #expect(SessionArchive.parentFolder("Work") == nil)
    #expect(SessionArchive.folderName("Work/Client A") == "Client A")
    #expect(SessionArchive.folderName("Work") == "Work")
    #expect(SessionArchive.folderDepth("Work") == 0)
    #expect(SessionArchive.folderDepth("Work/Client A/2026") == 2)
    #expect(SessionArchive.isFolder("Work/Client A", inside: "Work"))
    #expect(SessionArchive.isFolder("Work/Client A/2026", inside: "Work"))
    #expect(!SessionArchive.isFolder("Work", inside: "Work"))
    #expect(!SessionArchive.isFolder("Workshop", inside: "Work"))
}

/// Notes at every depth list with their folder path, and every folder at every
/// depth is listed, each parent before its children.
@Test func req_nested_folders() throws {
    let dir = try makeNestedArchive(
        notes: [
            "2026-06-18-090000.md",
            "Work/2026-06-18-100000.md",
            "Work/Client A/2026-06-18-110000.md",
            "Work/Client A/Q3/2026-06-18-120000.md",
            "Work/Client A/notes.txt",
        ],
        folders: ["Workshop", "Work/Empty", "Work/.hidden", ".dot"])
    defer { try? FileManager.default.removeItem(at: dir) }

    let byName = Dictionary(
        uniqueKeysWithValues: SessionArchive.list(in: dir).map { ($0.url.lastPathComponent, $0.folder) })
    #expect(byName.count == 4)
    #expect(byName["2026-06-18-090000.md"] == .some(nil))
    #expect(byName["2026-06-18-100000.md"] == "Work")
    #expect(byName["2026-06-18-110000.md"] == "Work/Client A")
    #expect(byName["2026-06-18-120000.md"] == "Work/Client A/Q3")

    #expect(SessionArchive.folders(in: dir)
        == ["Work", "Work/Client A", "Work/Client A/Q3", "Work/Empty", "Workshop"])
}

@Test func setFolderFilesANoteIntoASubfolder() throws {
    let dir = try makeNestedArchive(notes: ["2026-06-18-090000.md"], folders: ["Work/Client A"])
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = try #require(SessionArchive.list(in: dir).first)
    let filed = try #require(SessionArchive.setFolder("Work/Client A", for: file, root: dir))
    #expect(filed.folder == "Work/Client A")
    #expect(filed.url == SessionArchive.list(in: dir).first?.url)
    #expect(SessionArchive.setFolder("Work/../..", for: filed, root: dir) == nil)
}

@MainActor
@Test func theWriterStartsANoteInASubfolder() throws {
    let dir = try makeNestedArchive()
    defer { try? FileManager.default.removeItem(at: dir) }

    let writer = SessionWriter(store: TranscriptStore(), resolveDirectory: { dir })
    writer.start(folder: "Work/Client A")
    defer { writer.end(); writer.releaseNote() }
    let url = try #require(writer.currentFileURL)
    #expect(url.deletingLastPathComponent().lastPathComponent == "Client A")
    #expect(SessionArchive.list(in: dir).first?.folder == "Work/Client A")
}

@Test func aSubfolderKeepsItsOwnContextAndTags() throws {
    let dir = try makeNestedArchive(folders: ["Work/Client A"])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(SessionArchive.setFolderContext("Client calls", for: "Work/Client A", root: dir))
    #expect(SessionArchive.setFolderTags(["client"], for: "Work/Client A", root: dir))
    #expect(SessionArchive.folderContext("Work/Client A", root: dir) == "Client calls")
    #expect(SessionArchive.folderTags("Work/Client A", root: dir) == ["client"])
    #expect(SessionArchive.folderContext("Work", root: dir).isEmpty)
    #expect(SessionArchive.folderTags("Work", root: dir).isEmpty)
}

/// A new subfolder starts with a copy of its parent's context and tags; later
/// edits to either do not change the other.
@Test func req_nested_folder_inherit() throws {
    let dir = try makeNestedArchive(folders: ["Work"])
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(SessionArchive.setFolderContext("Work meetings", for: "Work", root: dir))
    #expect(SessionArchive.setFolderTags(["work", "urgent"], for: "Work", root: dir))

    #expect(SessionArchive.createFolder("Client A", inside: "Work", in: dir))
    #expect(SessionArchive.folders(in: dir) == ["Work", "Work/Client A"])
    #expect(SessionArchive.folderContext("Work/Client A", root: dir) == "Work meetings")
    #expect(SessionArchive.folderTags("Work/Client A", root: dir) == ["work", "urgent"])

    #expect(SessionArchive.setFolderContext("Client A calls", for: "Work/Client A", root: dir))
    #expect(SessionArchive.setFolderTags(["client"], for: "Work/Client A", root: dir))
    #expect(SessionArchive.setFolderContext("Changed", for: "Work", root: dir))
    #expect(SessionArchive.folderContext("Work/Client A", root: dir) == "Client A calls")
    #expect(SessionArchive.folderTags("Work/Client A", root: dir) == ["client"])
    #expect(SessionArchive.folderContext("Work", root: dir) == "Changed")
    #expect(SessionArchive.folderTags("Work", root: dir) == ["work", "urgent"])
}

@Test func createFolderInsideKeepsAnExistingSubfoldersDefaults() throws {
    let dir = try makeNestedArchive(folders: ["Work/Client A"])
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(SessionArchive.setFolderContext("Parent", for: "Work", root: dir))
    #expect(SessionArchive.setFolderContext("Own", for: "Work/Client A", root: dir))

    #expect(SessionArchive.createFolder("Client A", inside: "Work", in: dir))
    #expect(SessionArchive.folderContext("Work/Client A", root: dir) == "Own")
}

@Test func createFolderInsideRejectsAnUnsafeParentOrName() throws {
    let dir = try makeNestedArchive(folders: ["Work"])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(!SessionArchive.createFolder("A/B", inside: "Work", in: dir))
    #expect(!SessionArchive.createFolder("A", inside: "../Work", in: dir))
    #expect(SessionArchive.folders(in: dir) == ["Work"])
}

@Test func renameASubfolderKeepsItInItsParent() throws {
    let dir = try makeNestedArchive(
        notes: ["Work/Client A/Q3/2026-06-18-120000.md"], folders: ["Work/Client B"])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(SessionArchive.renameFolder(from: "Work/Client A", to: "Client C", in: dir))
    #expect(SessionArchive.folders(in: dir) == ["Work", "Work/Client B", "Work/Client C", "Work/Client C/Q3"])
    #expect(SessionArchive.list(in: dir).first?.folder == "Work/Client C/Q3")
    // A sibling of the same name blocks the rename, and a new name is one name.
    #expect(!SessionArchive.renameFolder(from: "Work/Client C", to: "Client B", in: dir))
    #expect(!SessionArchive.renameFolder(from: "Work/Client C", to: "X/Y", in: dir))
}

/// A delete moves the folder's sessions and subfolders into its parent, and
/// keeps the folder when one of them cannot move.
@Test func req_nested_folder_delete() throws {
    let dir = try makeNestedArchive(
        notes: [
            "Work/Client A/2026-06-18-110000.md",
            "Work/Client A/Q3/2026-06-18-120000.md",
        ])
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(SessionArchive.setFolderContext("Q3 context", for: "Work/Client A/Q3", root: dir))

    #expect(SessionArchive.deleteFolder("Work/Client A", in: dir))
    #expect(SessionArchive.folders(in: dir) == ["Work", "Work/Q3"])
    let byName = Dictionary(
        uniqueKeysWithValues: SessionArchive.list(in: dir).map { ($0.url.lastPathComponent, $0.folder) })
    #expect(byName["2026-06-18-110000.md"] == "Work")
    #expect(byName["2026-06-18-120000.md"] == "Work/Q3")
    #expect(SessionArchive.folderContext("Work/Q3", root: dir) == "Q3 context")
}

@Test func deleteFolderKeepsASubfolderThatWouldCollideInTheParent() throws {
    let dir = try makeNestedArchive(
        notes: ["Work/Client A/Q3/2026-06-18-120000.md", "Work/Q3/2026-06-18-130000.md"])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(!SessionArchive.deleteFolder("Work/Client A", in: dir))
    #expect(SessionArchive.folders(in: dir) == ["Work", "Work/Client A", "Work/Client A/Q3", "Work/Q3"])
    #expect(SessionArchive.list(in: dir).count == 2)
}

@Test func deleteATopLevelFolderMovesItsSubfoldersToTheRoot() throws {
    let dir = try makeNestedArchive(notes: ["Work/2026-06-18-100000.md", "Work/Client A/2026-06-18-110000.md"])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(SessionArchive.deleteFolder("Work", in: dir))
    #expect(SessionArchive.folders(in: dir) == ["Client A"])
    let byName = Dictionary(
        uniqueKeysWithValues: SessionArchive.list(in: dir).map { ($0.url.lastPathComponent, $0.folder) })
    #expect(byName["2026-06-18-100000.md"] == .some(nil))
    #expect(byName["2026-06-18-110000.md"] == "Client A")
}

@MainActor
@Test func aLiveNoteInASubfolderBlocksRenameAndDeleteOfEachAncestor() throws {
    let dir = try makeNestedArchive(folders: ["Work/Client A"])
    defer { try? FileManager.default.removeItem(at: dir) }
    let writer = SessionWriter(store: TranscriptStore(), resolveDirectory: { dir })
    writer.start(folder: "Work/Client A")
    defer { writer.end(); writer.releaseNote() }
    let live = writer.currentFileURL

    #expect(SessionArchive.folderContains(live, folder: "Work", in: dir))
    #expect(SessionArchive.folderContains(live, folder: "Work/Client A", in: dir))
    #expect(!SessionArchive.deleteFolder("Work", in: dir, excluding: live))
    #expect(!SessionArchive.renameFolder(from: "Work", to: "Jobs", in: dir, excluding: live))
    #expect(SessionArchive.folders(in: dir) == ["Work", "Work/Client A"])
}

@Test func theStorageMoveKeepsNestedFoldersAndTheirDefaults() throws {
    let source = try makeNestedArchive(notes: ["Work/Client A/2026-06-18-110000.md"])
    let dest = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-nested-dest-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: dest)
    }
    #expect(SessionArchive.setFolderContext("Client calls", for: "Work/Client A", root: source))
    #expect(SessionArchive.setFolderTags(["client"], for: "Work/Client A", root: source))

    #expect(SessionArchive.move(from: source, to: dest) == (moved: 1, skipped: 0))
    #expect(SessionArchive.list(in: dest).first?.folder == "Work/Client A")
    #expect(SessionArchive.folderContext("Work/Client A", root: dest) == "Client calls")
    #expect(SessionArchive.folderTags("Work/Client A", root: dest) == ["client"])
}

@Test func tagRenameAndDeleteReachSubfolderDefaults() throws {
    let dir = try makeNestedArchive(folders: ["Work/Client A"])
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(SessionArchive.setFolderTags(["client", "urgent"], for: "Work/Client A", root: dir))

    SessionArchive.renameTag(from: "client", to: "customer", in: dir)
    #expect(SessionArchive.folderTags("Work/Client A", root: dir) == ["customer", "urgent"])
    #expect(SessionArchive.removeTagFromFolderDefaults("urgent", in: dir) == 1)
    #expect(SessionArchive.folderTags("Work/Client A", root: dir) == ["customer"])
}

// MARK: - The sidebar tree (issue #155)

private let tree = ["Work", "Work/Client A", "Work/Client A/Q3", "Work/Empty", "Workshop"]

@Test func folderTreeHidesTheSubfoldersOfACollapsedFolder() {
    #expect(FolderTree.visible(tree, collapsed: [], matching: nil) == tree)
    #expect(FolderTree.visible(tree, collapsed: ["Work/Client A"], matching: nil)
        == ["Work", "Work/Client A", "Work/Empty", "Workshop"])
    #expect(FolderTree.visible(tree, collapsed: ["Work"], matching: nil) == ["Work", "Workshop"])
}

@Test func folderTreeShowsTheAncestorsOfAMatchWhileSearching() {
    #expect(FolderTree.visible(tree, collapsed: [], matching: ["Work/Client A/Q3"])
        == ["Work", "Work/Client A", "Work/Client A/Q3"])
    #expect(FolderTree.visible(tree, collapsed: [], matching: []) == [])
    #expect(FolderTree.visible(tree, collapsed: ["Work"], matching: ["Work/Empty"]) == ["Work"])
}

@Test func folderTreeCountsTheSessionsInEachSubfolder() {
    let sessions: [String?] = [nil, "Work", "Work/Client A", "Work/Client A/Q3", "Workshop"]
    #expect(FolderTree.sessionCount(of: "Work", in: sessions) == 3)
    #expect(FolderTree.sessionCount(of: "Work/Client A", in: sessions) == 2)
    #expect(FolderTree.sessionCount(of: "Work/Empty", in: sessions) == 0)
    #expect(FolderTree.sessionCount(of: "Workshop", in: sessions) == 1)
}

@Test func folderTreeListsTheChildrenOfAFolder() {
    #expect(FolderTree.children(of: nil, in: tree) == ["Work", "Workshop"])
    #expect(FolderTree.children(of: "Work", in: tree) == ["Work/Client A", "Work/Empty"])
    #expect(FolderTree.children(of: "Work/Empty", in: tree) == [])
}

@Test func folderTreeLayoutPutsSubfoldersBeforeTheParentsSessions() {
    #expect(FolderTree.layout(tree) == [
        .header("Work"),
        .header("Work/Client A"),
        .header("Work/Client A/Q3"), .sessions("Work/Client A/Q3"),
        .sessions("Work/Client A"),
        .header("Work/Empty"), .sessions("Work/Empty"),
        .sessions("Work"),
        .header("Workshop"), .sessions("Workshop"),
    ])
    #expect(FolderTree.layout([]) == [])
}

@Test func folderTreeDisplaysAPathNameByName() {
    #expect(FolderTree.displayPath("Work/Client A") == "Work › Client A")
    #expect(FolderTree.displayPath("Work") == "Work")
}

// MARK: - Review fixes (issue #155)

@Test func theWalkDoesNotListTheInsideOfAPackage() throws {
    let dir = try makeNestedArchive(
        notes: ["Work/Slides.key/Data/2026-06-18-100000.md"],
        folders: ["Work/Tool.app/Contents/MacOS"])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(SessionArchive.folders(in: dir) == ["Work"])
    #expect(SessionArchive.list(in: dir).isEmpty)
}

@Test func folderOrderKeepsCaseVariantsApart() {
    let sorted = ["work", "Work/A", "Work", "Workshop"].sorted(by: SessionArchive.folderOrder)
    #expect(sorted == ["Work", "Work/A", "work", "Workshop"])
}

@Test func collapseStateFollowsARenameAndADelete() {
    let collapsed: Set = ["Work", "Work/A", "Work/A/Q3", "Workshop"]
    #expect(FolderTree.renaming(collapsed, from: "Work", to: "Jobs")
        == ["Jobs", "Jobs/A", "Jobs/A/Q3", "Workshop"])
    #expect(FolderTree.removing(collapsed, folder: "Work/A") == ["Work", "Workshop"])
}

@Test func aDeleteThatWouldCollideMovesNothing() throws {
    let dir = try makeNestedArchive(notes: ["Work/2026-06-18-100000.md"], folders: ["Archive", "Work/Archive"])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(!SessionArchive.deleteFolder("Work", in: dir))
    #expect(SessionArchive.list(in: dir).first?.folder == "Work")
    #expect(SessionArchive.folders(in: dir) == ["Archive", "Work", "Work/Archive"])
}

@Test func deleteAFolderThatHoldsAFolderOfTheSameNameMovesNothing() throws {
    let dir = try makeNestedArchive(notes: ["Work/2026-06-18-100000.md", "Work/Work/2026-06-18-110000.md"])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(!SessionArchive.deleteFolder("Work", in: dir))
    #expect(SessionArchive.folders(in: dir) == ["Work", "Work/Work"])
    #expect(SessionArchive.list(in: dir).map(\.folder).sorted { ($0 ?? "") < ($1 ?? "") } == ["Work", "Work/Work"])
}

@Test func deleteFolderLeavesAPackageWhereItIs() throws {
    let dir = try makeNestedArchive(notes: ["Work/2026-06-18-100000.md"], folders: ["Work/Deck.key"])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(!SessionArchive.deleteFolder("Work", in: dir))
    let fm = FileManager.default
    #expect(fm.fileExists(atPath: dir.appendingPathComponent("Work/Deck.key").path))
    #expect(!fm.fileExists(atPath: dir.appendingPathComponent("Deck.key").path))
    #expect(SessionArchive.list(in: dir).first?.folder == "Work")
}

@Test func deleteFolderThatHoldsAnotherFileMovesNothing() throws {
    let dir = try makeNestedArchive(notes: ["Work/2026-06-18-100000.md", "Work/notes.txt"], folders: ["Work/A"])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(!SessionArchive.deleteFolder("Work", in: dir))
    #expect(SessionArchive.folders(in: dir) == ["Work", "Work/A"])
    #expect(SessionArchive.list(in: dir).first?.folder == "Work")
}

@Test func deleteFolderRemovesFindersDSStore() throws {
    let dir = try makeNestedArchive(
        notes: ["Work/2026-06-18-100000.md", "Work/.DS_Store", "Work/Client A/.DS_Store"])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(SessionArchive.deleteFolder("Work", in: dir))
    #expect(SessionArchive.folders(in: dir) == ["Client A"])
    #expect(SessionArchive.list(in: dir).first?.folder == nil)
}

@Test func aMoveThatFailsPutsTheEarlierMovesBack() throws {
    // A dangling symlink named Q3 in the parent: `fileExists` follows it and
    // says no, so the check passes, and then the move of the Q3 folder fails.
    let dir = try makeNestedArchive(
        notes: ["Work/A/2026-06-18-100000.md", "Work/A/Q3/2026-06-18-110000.md", "Work/A/R/2026-06-18-120000.md"])
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createSymbolicLink(
        at: dir.appendingPathComponent("Work/Q3"),
        withDestinationURL: dir.appendingPathComponent("missing"))

    #expect(!SessionArchive.deleteFolder("Work/A", in: dir))
    #expect(SessionArchive.folders(in: dir) == ["Work", "Work/A", "Work/A/Q3", "Work/A/R"])
    #expect(Set(SessionArchive.list(in: dir).map(\.folder)) == ["Work/A", "Work/A/Q3", "Work/A/R"])
}

@Test func aFolderNamedOutsideTheAppWorksByItsExactName() throws {
    let dir = try makeNestedArchive(notes: ["Work/2026-06-18-100000.md"], folders: ["Work ", "Work/a:b"])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(SessionArchive.setFolderContext("Spaced", for: "Work ", root: dir))
    #expect(SessionArchive.folderContext("Work", root: dir).isEmpty)
    let note = try #require(SessionArchive.list(in: dir).first)
    #expect(SessionArchive.setFolder("Work/a:b", for: note, root: dir)?.folder == "Work/a:b")

    #expect(SessionArchive.deleteFolder("Work ", in: dir))
    #expect(SessionArchive.folders(in: dir) == ["Work", "Work/a:b"])
    #expect(SessionArchive.list(in: dir).first?.folder == "Work/a:b")
}

@Test func deleteFolderRefusesAHiddenDirectory() throws {
    let dir = try makeNestedArchive(notes: ["Work/2026-06-18-100000.md"], folders: ["Work/.git"])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(!SessionArchive.deleteFolder("Work", in: dir))
    #expect(SessionArchive.list(in: dir).first?.folder == "Work")
}

@Test func expandingAFolderOpensEachAncestor() {
    #expect(FolderTree.expanding(["Work", "Work/A", "Workshop", "Work/B"], toShow: "Work/A/Q3")
        == ["Workshop", "Work/B"])
}

@Test func scanGivesTheNotesAndTheFoldersFromOneWalk() throws {
    let dir = try makeNestedArchive(notes: ["Work/A/2026-06-18-100000.md"])
    defer { try? FileManager.default.removeItem(at: dir) }

    let scan = SessionArchive.scan(dir)
    #expect(scan.folders == SessionArchive.folders(in: dir))
    #expect(scan.notes == SessionArchive.list(in: dir))
}

/// What is left in a folder after its sessions and subfolders move out — its
/// context and tags and the files that macOS writes, such as a custom icon —
/// is deleted with it.
@Test func deleteFolderDeletesItsOwnFilesWithIt() throws {
    let dir = try makeNestedArchive(notes: [
        "Work/2026-06-18-100000.md", "Work/A/2026-06-18-110000.md",
        "Work/Icon\r", "Work/.DS_Store", "Work/.localized", "Work/._2026-06-18-100000.md",
    ])
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(SessionArchive.setFolderContext("Gone", for: "Work", root: dir))
    #expect(SessionArchive.setFolderTags(["gone"], for: "Work", root: dir))

    #expect(SessionArchive.deleteFolder("Work", in: dir))
    #expect(SessionArchive.folders(in: dir) == ["A"])
    #expect(Set(SessionArchive.list(in: dir).map(\.folder)) == [nil, "A"])
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Work").path))
}

/// A file locked in Finder stops the last step of a delete: the sessions and
/// subfolders that moved out are put back.
@Test func aLockedFileInTheFolderPutsTheMovesBack() throws {
    let dir = try makeNestedArchive(notes: ["Work/2026-06-18-100000.md", "Work/A/2026-06-18-110000.md", "Work/.DS_Store"])
    let locked = dir.appendingPathComponent("Work/.DS_Store")
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
    defer {
        try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path)
        try? FileManager.default.removeItem(at: dir)
    }

    #expect(!SessionArchive.deleteFolder("Work", in: dir))
    #expect(SessionArchive.folders(in: dir) == ["Work", "Work/A"])
    #expect(Set(SessionArchive.list(in: dir).map(\.folder)) == ["Work", "Work/A"])
}
