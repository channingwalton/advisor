import CoreServices
import Foundation
import Testing

@testable import Advisor

// MARK: - The Sessions browser reloads a note that changes on disk (issue #133)

private let root = "/Users/me/Sessions"

@Test func aNoteChangeAffectsTheBrowser() {
    #expect(SessionArchive.affectsBrowser(path: "\(root)/2026-11-06-101500.md", isDirectory: false, root: root))
    #expect(SessionArchive.affectsBrowser(
        path: "\(root)/Work/Client A/2026-11-06-101500.md", isDirectory: false, root: root))
}

@Test func aFolderOrItsDefaultsAffectTheBrowser() {
    #expect(SessionArchive.affectsBrowser(path: "\(root)/Work", isDirectory: true, root: root))
    #expect(SessionArchive.affectsBrowser(path: "\(root)/Work/Client A", isDirectory: true, root: root))
    #expect(SessionArchive.affectsBrowser(path: "\(root)/Work/.context.md", isDirectory: false, root: root))
    #expect(SessionArchive.affectsBrowser(path: "\(root)/Work/.tags", isDirectory: false, root: root))
}

@Test func theSessionFolderItselfAffectsTheBrowser() {
    #expect(SessionArchive.affectsBrowser(path: root, isDirectory: true, root: root))
}

/// Finder's `.DS_Store`, an editor's swap, backup or temporary file, and other
/// files that the walk does not list change nothing that the browser shows.
@Test func otherFilesDoNotAffectTheBrowser() {
    for name in [
        ".DS_Store", ".2026-11-06-101500.md.swp", "2026-11-06-101500.md~",
        "2026-11-06-101500.md.tmp", "notes.md", "README.txt",
    ] {
        #expect(!SessionArchive.affectsBrowser(path: "\(root)/Work/\(name)", isDirectory: false, root: root),
            "\(name)")
    }
}

/// The walk skips dot-directories and what they hold.
@Test func aChangeInADotDirectoryDoesNotAffectTheBrowser() {
    #expect(!SessionArchive.affectsBrowser(path: "\(root)/.obsidian", isDirectory: true, root: root))
    #expect(!SessionArchive.affectsBrowser(
        path: "\(root)/.trash/2026-11-06-101500.md", isDirectory: false, root: root))
    #expect(!SessionArchive.affectsBrowser(
        path: "\(root)/Work/.hidden/2026-11-06-101500.md", isDirectory: false, root: root))
}

@Test func aChangeOutsideTheSessionFolderDoesNotAffectTheBrowser() {
    #expect(!SessionArchive.affectsBrowser(path: "/Users/me/2026-11-06-101500.md", isDirectory: false, root: root))
    #expect(!SessionArchive.affectsBrowser(
        path: "/Users/me/Sessions Old/2026-11-06-101500.md", isDirectory: false, root: root))
    #expect(!SessionArchive.affectsBrowser(path: "/Users/me", isDirectory: true, root: root))
}

// MARK: - Which FSEvents changes the watch reports

private let note = "\(root)/2026-11-06-101500.md"

private func flags(_ values: Int...) -> FSEventStreamEventFlags {
    FSEventStreamEventFlags(values.reduce(0, |))
}

/// A note that is written, saved by a rename, created or removed is reported.
@Test func aChangeToANoteIsReported() {
    for flag in [
        kFSEventStreamEventFlagItemModified, kFSEventStreamEventFlagItemRenamed,
        kFSEventStreamEventFlagItemCreated, kFSEventStreamEventFlagItemRemoved,
    ] {
        #expect(SessionFolderWatch.reports(
            path: note, flags: flags(flag, kFSEventStreamEventFlagItemIsFile), root: root))
    }
    #expect(SessionFolderWatch.reports(
        path: "\(root)/Work", flags: flags(kFSEventStreamEventFlagItemCreated, kFSEventStreamEventFlagItemIsDir),
        root: root))
}

/// macOS and sync clients set attributes on a note, for example when another
/// app opens it: the browser shows none of them.
@Test func anAttributeChangeIsNotReported() {
    for flag in [
        kFSEventStreamEventFlagItemXattrMod, kFSEventStreamEventFlagItemInodeMetaMod,
        kFSEventStreamEventFlagItemFinderInfoMod, kFSEventStreamEventFlagItemChangeOwner,
    ] {
        #expect(!SessionFolderWatch.reports(
            path: note, flags: flags(flag, kFSEventStreamEventFlagItemIsFile), root: root))
    }
}

@Test func aChangeToAFileThatTheBrowserDoesNotShowIsNotReported() {
    #expect(!SessionFolderWatch.reports(
        path: "\(root)/.DS_Store", flags: flags(kFSEventStreamEventFlagItemModified, kFSEventStreamEventFlagItemIsFile),
        root: root))
}

/// The live writer rewrites its note from memory, so another app's change to
/// it does not last. A sync client's attribute change can arrive with the
/// flags of the writer's earlier rewrites, which must not reload the list.
@Test func aChangeToTheLiveNoteIsNotReported() {
    let live = URL(fileURLWithPath: note)
    let modified = flags(kFSEventStreamEventFlagItemModified, kFSEventStreamEventFlagItemIsFile)
    #expect(!SessionFolderWatch.reports(path: note, flags: modified, root: root, ignoring: live))
    #expect(SessionFolderWatch.reports(
        path: "\(root)/2026-11-06-101600.md", flags: modified, root: root, ignoring: live))
    #expect(SessionFolderWatch.reports(
        path: root, flags: flags(kFSEventStreamEventFlagMustScanSubDirs), root: root, ignoring: live))
}

/// FSEvents dropped events, or the session folder moved: the list must be
/// read again, whatever the path.
@Test func aChangeThatFSEventsCannotItemiseIsReported() {
    for flag in [
        kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped,
        kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagRootChanged,
    ] {
        #expect(SessionFolderWatch.reports(path: root, flags: flags(flag), root: root))
    }
}

// MARK: - The FSEvents watch, against the real file system

/// A new, empty folder for one watch test. Remove it on teardown.
private func makeWatchedFolder() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-watch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Write "x" to each of `urls`, in order, from a child process: the watch
/// ignores the changes that its own process makes.
private func writeFromAnotherProcess(_ urls: [URL]) throws {
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/sh")
    shell.arguments = ["-c", #"for f in "$@"; do printf x > "$f"; done"#, "sh"] + urls.map(\.path)
    try shell.run()
    shell.waitUntilExit()
}

/// Wait, at most 10 s, until a batch reports a path that ends with `name`.
@MainActor
private func waitForBatch(naming name: String, in batches: () -> [[String]]) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !batches().joined().contains(where: { $0.hasSuffix("/" + name) }), Date() < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
}

/// The app's own writes are ignored, and so are the live note and a file
/// that the browser does not show. A note that another app changes is
/// reported.
@MainActor
@Test func req_sessions_reload_on_disk() async throws {
    let dir = try makeWatchedFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let live = dir.appendingPathComponent("2026-11-06-101400.md")
    var batches: [[String]] = []
    let watch = SessionFolderWatch(ignoring: { live }) { batches.append($0) }
    watch.watch(dir)
    defer { watch.stop() }

    let own = dir.appendingPathComponent("2026-11-06-101500.md")
    let other = dir.appendingPathComponent("2026-11-06-101600.md")
    try "x".write(to: own, atomically: true, encoding: .utf8)
    try writeFromAnotherProcess([live, dir.appendingPathComponent(".DS_Store"), other])
    try await waitForBatch(naming: other.lastPathComponent) { batches }

    // FSEvents gives events in order, so the earlier changes would show by now.
    let reported = batches.joined().map { URL(fileURLWithPath: $0).lastPathComponent }
    #expect(reported.contains(other.lastPathComponent))
    #expect(!reported.contains(own.lastPathComponent))
    #expect(!reported.contains(live.lastPathComponent))
    #expect(!reported.contains(".DS_Store"))
}

/// A session folder changed in Preferences moves the watch: the old folder
/// is no longer reported.
@MainActor
@Test func theWatchFollowsANewFolder() async throws {
    let old = try makeWatchedFolder()
    let new = try makeWatchedFolder()
    defer {
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.removeItem(at: new)
    }
    var batches: [[String]] = []
    let watch = SessionFolderWatch { batches.append($0) }
    watch.watch(old)
    watch.watch(new)
    defer { watch.stop() }

    let inOld = old.appendingPathComponent("2026-11-06-101500.md")
    let inNew = new.appendingPathComponent("2026-11-06-101600.md")
    try writeFromAnotherProcess([inOld, inNew])
    try await waitForBatch(naming: inNew.lastPathComponent) { batches }
    // A stream left on the old folder would deliver on its own timing.
    try await Task.sleep(for: .seconds(1))

    let reported = batches.joined().map { URL(fileURLWithPath: $0).lastPathComponent }
    #expect(reported.contains(inNew.lastPathComponent))
    #expect(!reported.contains(inOld.lastPathComponent))
}

/// A batch can reload the list and so move the watch to a new folder, as
/// after a folder change in Preferences. The move stops the stream that gave
/// the batch, and the new folder is then reported.
@MainActor
@Test func theWatchCanMoveFromInsideABatch() async throws {
    let old = try makeWatchedFolder()
    let new = try makeWatchedFolder()
    defer {
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.removeItem(at: new)
    }
    var batches: [[String]] = []
    var watch: SessionFolderWatch?
    watch = SessionFolderWatch { paths in
        batches.append(paths)
        watch?.watch(new)
    }
    watch?.watch(old)
    defer { watch?.stop() }

    let inOld = old.appendingPathComponent("2026-11-06-101500.md")
    let inNew = new.appendingPathComponent("2026-11-06-101600.md")
    try writeFromAnotherProcess([inOld])
    try await waitForBatch(naming: inOld.lastPathComponent) { batches }
    try writeFromAnotherProcess([inNew])
    try await waitForBatch(naming: inNew.lastPathComponent) { batches }

    let reported = batches.joined().map { URL(fileURLWithPath: $0).lastPathComponent }
    #expect(reported.contains(inOld.lastPathComponent))
    #expect(reported.contains(inNew.lastPathComponent))
}

/// A root that `resolvedFolder` gives can end in a `/`; the result is the same.
@Test func aRootWithATrailingSlashGivesTheSameResult() {
    #expect(SessionArchive.affectsBrowser(
        path: "\(root)/2026-11-06-101500.md", isDirectory: false, root: root + "/"))
    #expect(SessionArchive.affectsBrowser(path: root, isDirectory: true, root: root + "/"))
}
