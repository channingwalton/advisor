import Foundation
import Testing
@testable import Advisor

private func nestedArchive() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func nestedFoldersListAndFileNotes() throws {
    let root = try nestedArchive()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(SessionArchive.createFolder("Work/Project/Meetings", in: root))
    #expect(SessionArchive.folders(in: root) == ["Work", "Work/Project", "Work/Project/Meetings"])
    let url = root.appendingPathComponent("2026-11-18-090000.md")
    try "transcript".write(to: url, atomically: true, encoding: .utf8)
    let file = SessionFile(url: url, date: Date(), folder: nil)
    let moved = try #require(SessionArchive.setFolder("Work/Project/Meetings", for: file, root: root))
    #expect(SessionArchive.list(in: root).map(\.folder) == ["Work/Project/Meetings"])
    #expect(SessionArchive.contents(of: moved) == "transcript")
    #expect(SessionArchive.relocated(file, in: root)?.url == moved.url)
}

@Test func nestedDefaultsAreIndependentAndFollowRename() throws {
    let root = try nestedArchive()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(SessionArchive.setFolderContext("parent", for: "Work", root: root))
    #expect(SessionArchive.setFolderTags(["Parent"], for: "Work", root: root))
    #expect(SessionArchive.createFolder("Work/Child", in: root))
    #expect(SessionArchive.folderContext("Work/Child", root: root).isEmpty)
    #expect(SessionArchive.folderTags("Work/Child", root: root).isEmpty)
    #expect(FolderRecordingDefaults.load(
        pendingFolder: "Work/Child", sessionActive: false,
        library: [SavedTag(name: "Parent", colorHex: "0x000000")], root: root)
        == FolderRecordingDefaults(context: "", tags: []))
    #expect(SessionArchive.setFolderContext("child", for: "Work/Child", root: root))
    #expect(SessionArchive.setFolderTags(["Child"], for: "Work/Child", root: root))
    #expect(SessionArchive.renameFolder(from: "Work", to: "Projects", in: root))
    #expect(SessionArchive.folderContext("Projects/Child", root: root) == "child")
    #expect(SessionArchive.folderTags("Projects/Child", root: root) == ["Child"])
    #expect(SessionArchive.renameFolder(from: "Projects/Child", to: "Renamed", in: root))
    #expect(SessionArchive.folders(in: root) == ["Projects", "Projects/Renamed"])
}

@Test func nestedFolderDeletionPromotesChildrenWithoutLosingDefaults() throws {
    let root = try nestedArchive()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(SessionArchive.setFolderContext("child", for: "Work/Project/Child", root: root))
    #expect(SessionArchive.setFolderTags(["Child"], for: "Work/Project/Child", root: root))
    let url = root.appendingPathComponent("Work/Project/2026-11-18-090000.md")
    try "kept".write(to: url, atomically: true, encoding: .utf8)
    #expect(SessionArchive.deleteFolder("Work/Project", in: root))
    #expect(SessionArchive.list(in: root).map(\.folder) == ["Work"])
    #expect(SessionArchive.folderContext("Work/Child", root: root) == "child")
    #expect(SessionArchive.folderTags("Work/Child", root: root) == ["Child"])
}

@Test func nestedFolderDeletionRefusesChildCollision() throws {
    let root = try nestedArchive()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(SessionArchive.setFolderContext("kept", for: "Work/Project", root: root))
    #expect(SessionArchive.createFolder("Work/Project/Child", in: root))
    #expect(SessionArchive.createFolder("Work/Child", in: root))
    #expect(!SessionArchive.deleteFolder("Work/Project", in: root))
    #expect(SessionArchive.folderContext("Work/Project", root: root) == "kept")
    #expect(SessionArchive.folders(in: root).contains("Work/Project/Child"))
}

@Test func nestedFolderPathsRejectTraversalAndHiddenComponents() throws {
    let root = try nestedArchive()
    defer { try? FileManager.default.removeItem(at: root) }
    for path in ["../outside", "Work/../outside", "/absolute", "Work//Child", "Work/", "Work/.hidden", "Work/./Child", "Work/a:b"] {
        #expect(!SessionArchive.createFolder(path, in: root))
        #expect(!SessionArchive.setFolderContext("x", for: path, root: root))
        #expect(!SessionArchive.deleteFolder(path, in: root))
    }
    // Recursive enumeration must not follow directory symlinks or loop.
    #expect(SessionArchive.createFolder("Work/Child", in: root))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Work/Child/Loop"), withDestinationURL: root)
    #expect(SessionArchive.folders(in: root) == ["Work", "Work/Child"])
    #expect(!SessionArchive.createFolder("Work/Child/Loop/Escape", in: root))
    #expect(!SessionArchive.setFolderContext("x", for: "Work/Child/Loop", root: root))
    #expect(!SessionArchive.renameFolder(from: "Work/Child/Loop", to: "Moved", in: root))
    #expect(!SessionArchive.deleteFolder("Work/Child/Loop", in: root))
}

@MainActor @Test func nestedWriterAndAncestorOwnership() throws {
    let root = try nestedArchive()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = SessionWriter(store: TranscriptStore(), resolveDirectory: { root })
    writer.start(folder: "Work/Project/Child")
    let url = try #require(writer.currentFileURL)
    #expect(SessionArchive.list(in: root).first?.folder == "Work/Project/Child")
    for folder in ["Work", "Work/Project", "Work/Project/Child"] {
        #expect(!SessionArchive.renameFolder(from: folder, to: "Renamed", in: root, excluding: url))
        #expect(!SessionArchive.deleteFolder(folder, in: root, excluding: url))
    }
    writer.end()
}

@Test func nestedTreeKeepsSubtreesTogetherAndCollapsesDescendants() {
    let folders = ["Work", "Work/Child", "Work/Child/Deep", "Work/Other", "Work notes"]
    #expect(SessionFolderTree.visible(folders: folders, matching: nil, collapsed: []) == folders)
    #expect(SessionFolderTree.visible(folders: folders, matching: nil, collapsed: ["Work"]) == ["Work", "Work notes"])
    #expect(SessionFolderTree.visible(folders: folders, matching: nil, collapsed: ["Work/Child"])
        == ["Work", "Work/Child", "Work/Other", "Work notes"])
    #expect(SessionFolderTree.visible(folders: folders, matching: ["Work/Child/Deep"], collapsed: ["Work"])
        == ["Work", "Work/Child", "Work/Child/Deep"])
    #expect(SessionFolderTree.visible(folders: folders, matching: [], collapsed: []).isEmpty)
}

@Test func nestedEnumerationKeepsExistingWhitespaceNames() throws {
    let root = try nestedArchive()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Work / Child ")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let note = folder.appendingPathComponent("2026-11-18-090000.md")
    try "kept".write(to: note, atomically: true, encoding: .utf8)
    #expect(SessionArchive.list(in: root).first?.folder == "Work / Child ")
    #expect(SessionArchive.folders(in: root) == ["Work ", "Work / Child "])
    #expect(SessionArchive.setFolderContext("exact", for: "Work / Child ", root: root))
    #expect(SessionArchive.folderContext("Work / Child ", root: root) == "exact")
    #expect(SessionArchive.folderContext("Work/Child", root: root).isEmpty)
}

@Test func nestedStorageMoveAndTagMaintenance() throws {
    let source = try nestedArchive(), dest = try nestedArchive()
    defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
    #expect(SessionArchive.setFolderContext("child", for: "Work/Child", root: source))
    #expect(SessionArchive.setFolderTags(["Old"], for: "Work/Child", root: source))
    let url = source.appendingPathComponent("Work/Child/2026-11-18-090000.md")
    try "---\ntags: Old\n---\n\ntranscript".write(to: url, atomically: true, encoding: .utf8)
    #expect(SessionArchive.renameTag(from: "Old", to: "New", in: source) == 1)
    #expect(SessionArchive.folderTags("Work/Child", root: source) == ["New"])
    #expect(SessionArchive.move(from: source, to: dest).moved == 1)
    #expect(SessionArchive.list(in: dest).first?.folder == "Work/Child")
    #expect(SessionArchive.folderContext("Work/Child", root: dest) == "child")
    #expect(SessionArchive.removeTagFromFolderDefaults("New", in: dest) == 1)
}
