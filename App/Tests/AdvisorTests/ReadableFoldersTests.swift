import Foundation
import Testing

@testable import Advisor

// The list edits of Preferences → Files (GHSA-6xc8-f55f-jxqr). The sidecar
// enforces the list; these tests cover what the app writes.

private func tempConfig() -> (dir: URL, file: URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (dir, dir.appendingPathComponent("config.json"))
}

@Test func readableFoldersAddingAppendsANewFolderOnly() {
    let home = "/Users/x"
    let list = ["/Users/x/Notes", "~/dev"]
    #expect(ReadableFolders.adding("/Users/x/Work", to: list, home: home) == list + ["/Users/x/Work"])
    // The same folder in another spelling is not added twice.
    for same in ["/Users/x/Notes", "/Users/x/Notes/", "~/Notes", "/Users/x/dev", "/Users/x/Work/../dev"] {
        #expect(ReadableFolders.adding(same, to: list, home: home) == list, "\(same)")
    }
}

@Test func readableFoldersRemovingDropsThatFolderInEverySpelling() {
    let home = "/Users/x"
    #expect(ReadableFolders.removing("~/dev", from: ["/Users/x/Notes", "~/dev"], home: home) == ["/Users/x/Notes"])
    #expect(ReadableFolders.removing("~/other", from: ["~/dev"], home: home) == ["~/dev"])
    // One Remove revokes the folder, however the list spells it.
    let twice = ["~/Notes", "/Users/x/Notes/", "~/dev", "~/Notes"]
    #expect(ReadableFolders.removing("~/Notes", from: twice, home: home) == ["~/dev"])
}

@Test func readableFoldersDisplayShowsTheHomeFolderAsTilde() {
    let home = "/Users/x"
    #expect(ReadableFolders.display("/Users/x/Library/Mobile Documents", home: home) == "~/Library/Mobile Documents")
    #expect(ReadableFolders.display("/Users/x", home: home) == "~")
    #expect(ReadableFolders.display("/Users/xy/Notes", home: home) == "/Users/xy/Notes")
    #expect(ReadableFolders.display("~/dev", home: home) == "~/dev")
}

// An edit applies to the list in the file as it is then, not to a copy that the
// window loaded earlier, and keeps the other settings.
@Test func readableFoldersUpdateEditsTheFilesListNow() throws {
    let (dir, file) = tempConfig()
    defer { try? FileManager.default.removeItem(at: dir) }
    var disk = AdvisorConfig()
    disk.readableFolders = ["~/Notes"]
    disk.appearance = "dark"
    disk.save(to: file)
    let new = ReadableFolders.update(at: file) { $0 + ["~/dev"] }
    #expect(new == .saved(["~/Notes", "~/dev"]))
    let saved = AdvisorConfig.load(from: file)
    #expect(saved.readableFolders == ["~/Notes", "~/dev"])
    #expect(saved.appearance == "dark")
    #expect(ReadableFolders.load(from: file) == ["~/Notes", "~/dev"])
}

@Test func readableFoldersUpdateWithNoFileCreatesIt() {
    let (dir, file) = tempConfig()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(ReadableFolders.load(from: file) == [])
    #expect(ReadableFolders.update(at: file) { $0 + ["~/Notes"] } == .saved(["~/Notes"]))
    #expect(AdvisorConfig.load(from: file).readableFolders == ["~/Notes"])
}

// A file that does not decode has an unknown list: an edit writes nothing, and
// load says so (nil), so the window can tell the user.
@Test func readableFoldersUpdateLeavesAnUndecodableFileAsItIs() throws {
    let (dir, file) = tempConfig()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let broken = Data(#"{"readableFolders":["~/Notes"]"#.utf8)
    try broken.write(to: file)
    #expect(ReadableFolders.update(at: file) { _ in [] } == .unusable)
    #expect(try Data(contentsOf: file) == broken)
    #expect(ReadableFolders.load(from: file) == nil)
}

// Add and Remove (the tab's two edits) apply to the file's list as it is at
// that moment: a folder removed from the file since an earlier read is not
// added back.
@Test func readableFoldersAddAndRemoveEditTheFilesListNow() throws {
    let (dir, file) = tempConfig()
    defer { try? FileManager.default.removeItem(at: dir) }
    let home = "/Users/x"
    var disk = AdvisorConfig()
    disk.readableFolders = ["~/Notes", "~/Private", "~/dev"]
    disk.save(to: file)
    #expect(ReadableFolders.load(from: file) == ["~/Notes", "~/Private", "~/dev"])
    // Then a hand edit removes ~/Private.
    disk.readableFolders = ["~/Notes", "~/dev"]
    disk.save(to: file)
    #expect(ReadableFolders.remove("~/dev", at: file, home: home) == .saved(["~/Notes"]))
    #expect(ReadableFolders.add(["/Users/x/Work", "/Users/x/Notes"], at: file, home: home)
        == .saved(["~/Notes", "/Users/x/Work"]))
    #expect(ReadableFolders.load(from: file) == ["~/Notes", "/Users/x/Work"])
}

// The sidecar grants a folder through each entry's resolved path, so one
// Remove takes out an entry that is a symlink to it, or another letter case
// of it on a volume that folds case.
@Test func readableFoldersRemovingResolvesSymlinksAndLetterCase() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let notes = base.appendingPathComponent("Notes")
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    let link = base.appendingPathComponent("NotesLink")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: notes)
    let other = base.appendingPathComponent("Other").path
    #expect(ReadableFolders.removing(notes.path, from: [link.path, other]) == [other])
    let lower = base.appendingPathComponent("notes").path
    if FileManager.default.fileExists(atPath: lower) {
        #expect(ReadableFolders.removing(notes.path, from: [lower, other]) == [other])
        // Add compares exact paths, so this shows that the disk's letter case
        // is resolved, which Remove's case fold would hide.
        #expect(ReadableFolders.adding(lower, to: [notes.path]) == [notes.path])
    }
}

// The sidecar ignores a relative entry, so it never stands for the absolute
// folder of the same name, even when the app's working folder is that
// folder's parent (as the home folder often is).
@Test func readableFoldersARelativeEntryMatchesOnlyItself() {
    let home = FileManager.default.currentDirectoryPath
    let notes = home + "/Notes"
    #expect(ReadableFolders.adding(notes, to: ["Notes"], home: home) == ["Notes", notes])
    #expect(ReadableFolders.removing(notes, from: ["Notes"], home: home) == ["Notes"])
    #expect(ReadableFolders.removing("Notes", from: ["Notes", notes], home: home) == [notes])
}

// A write that fails reports the list that the file still holds, so the tab
// never shows a folder as removed while agents can still read it.
@Test func readableFoldersUpdateThatCannotWriteReportsTheFilesList() throws {
    let (dir, file) = tempConfig()
    var disk = AdvisorConfig()
    disk.readableFolders = ["~/Notes"]
    disk.save(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }
    #expect(ReadableFolders.update(at: file) { _ in [] } == .notSaved(["~/Notes"]))
    #expect(ReadableFolders.load(from: file) == ["~/Notes"])
}

// The recording window's context save keeps the readable folders, and leaves
// a file that does not decode as it is.
@Test func saveContextKeepsTheReadableFoldersAndAnUndecodableFile() throws {
    let (dir, file) = tempConfig()
    defer { try? FileManager.default.removeItem(at: dir) }
    var disk = AdvisorConfig()
    disk.readableFolders = ["~/Notes"]
    disk.save(to: file)
    #expect(AdvisorConfig.saveContext(named: "Standup", text: "Daily standup", at: file)?.map(\.name) == ["Standup"])
    let saved = AdvisorConfig.load(from: file)
    #expect(saved.readableFolders == ["~/Notes"])
    #expect(saved.contexts.map(\.name) == ["Standup"])
    let broken = Data(#"{"readableFolders":["~/Notes"]"#.utf8)
    try broken.write(to: file)
    #expect(AdvisorConfig.saveContext(named: "Retro", text: "Fortnightly", at: file) == nil)
    #expect(try Data(contentsOf: file) == broken)
}

// The list is read and written in the raw JSON by the sidecar's rule, so a key
// that the app cannot decode neither hides the list nor blocks an edit, and an
// edit leaves every other key as the file holds it.
@Test func readableFoldersWorkWhenAnotherKeyCannotBeDecoded() throws {
    let (dir, file) = tempConfig()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let body = #"{"model":5,"contexts":[{"name":"no id"}],"readableFolders":["~/Private",7],"futureKey":{"a":[1,true,null]}}"#
    try Data(body.utf8).write(to: file)
    guard case .unusable = AdvisorConfig.fileState(at: file) else {
        Issue.record("the app's decode should refuse this file")
        return
    }
    #expect(ReadableFolders.load(from: file) == ["~/Private"])
    #expect(ReadableFolders.remove("~/Private", at: file) == .saved([]))
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
    var expected = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    expected["readableFolders"] = [String]()
    // As JSON text: an NSDictionary compare treats 1 and true as equal.
    let text = { (v: Any) in try JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) }
    #expect(try text(json) == text(expected))
}

// A folder that does not exist is compared through its deepest existing
// parent, resolved as the sidecar resolves it, and Remove ignores letter case:
// once the folder exists, the sidecar may resolve both spellings to it.
@Test func readableFoldersRemovingMatchesAMissingFolderAsTheSidecarWould() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let real = base.appendingPathComponent("Real")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let link = base.appendingPathComponent("Link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let viaLink = link.appendingPathComponent("Notes").path
    #expect(ReadableFolders.removing(real.appendingPathComponent("Notes").path, from: [viaLink]) == [])
    #expect(ReadableFolders.removing(real.appendingPathComponent("notes").path, from: [viaLink]) == [])
    // Adding keeps the letter case apart, so a distinct folder is still added.
    let other = real.appendingPathComponent("notes").path
    #expect(ReadableFolders.adding(other, to: [viaLink]) == [viaLink, other])
}

// The sidecar grants an entry in its lexical form and in its symlink-first
// form: with `Link -> Real`, `Link/../Notes` grants `Notes` beside `Link` and
// `Notes` beside `Real` (`judgedForms` in sidecar/src/toolPolicy.ts). A Remove of
// either folder takes the entry out (code review 2026-11-10).
@Test func readableFoldersRemovingMatchesEachFormThatTheSidecarGrants() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let real = base.appendingPathComponent("a/Real")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let link = base.appendingPathComponent("Link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let entry = link.path + "/../Notes"
    let lexical = base.appendingPathComponent("Notes").path
    let symlinkFirst = base.appendingPathComponent("a/Notes").path
    // While Notes does not exist, and after it exists beside Real.
    for _ in 0..<2 {
        #expect(ReadableFolders.removing(lexical, from: [entry]) == [])
        #expect(ReadableFolders.removing(symlinkFirst, from: [entry]) == [])
        #expect(ReadableFolders.removing(base.appendingPathComponent("Other").path, from: [entry]) == [entry])
        try FileManager.default.createDirectory(atPath: symlinkFirst, withIntermediateDirectories: true)
    }
}

// APFS folds more than ASCII case: `Noteſ` (long s) opens `Notes`. For a folder
// that does not exist yet, the sidecar later resolves such an entry to the
// folder, so a Remove of `Notes` takes it out too (code review 2026-11-10).
@Test func readableFoldersRemovingFoldsCaseAsTheDiskDoes() {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let longS = base + "/Note\u{17F}"
    let ligature = base + "/\u{FB01}le"
    #expect(ReadableFolders.removing(base + "/Notes", from: [longS, base + "/Other"]) == [base + "/Other"])
    #expect(ReadableFolders.removing(base + "/FILE", from: [ligature]) == [])
}
