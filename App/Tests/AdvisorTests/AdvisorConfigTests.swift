import Foundation
import SwiftUI
import Testing

@testable import Advisor

// The custom init(from:) exists so a partial/stale config.json is tolerated
// rather than throwing on a missing key — which would make load() fall back to
// a full default and the next save() wipe every setting (issue #65).

@Test func configPartialDecodeKeepsDefaultsForMissingKeys() throws {
    let json = Data(#"{"provider":"codex"}"#.utf8)
    let c = try JSONDecoder().decode(AdvisorConfig.self, from: json)
    #expect(c.provider == "codex")            // the one present key
    #expect(c.model == "")                    // the rest fall back to defaults
    #expect(c.effort == "")
    #expect(c.authMode == "subscription")
    #expect(c.appearance == "system")
    #expect(c.allowMcpActions == false)
    #expect(c.triggerSensitivity == "balanced")
    #expect(c.triggers == AdvisorConfig.Triggers())
    #expect(c.logTranscriptText == false)      // transcript text stays out of the log by default
    #expect(c.readableFolders == [])           // agents read no local file by default
}

@Test func configDecodeIgnoresUnknownKeys() throws {
    // A key from a future version must not make the decode throw.
    let json = Data(#"{"provider":"claude","someFutureKey":42}"#.utf8)
    let c = try JSONDecoder().decode(AdvisorConfig.self, from: json)
    #expect(c.provider == "claude")
}

@Test func configPartialDecodePreservesUnrelatedPresentKeys() throws {
    // Two keys present, the rest absent: both survive (a throwing synthesised
    // decoder would lose everything on the first missing key).
    let json = Data(#"{"appearance":"dark","allowMcpActions":true}"#.utf8)
    let c = try JSONDecoder().decode(AdvisorConfig.self, from: json)
    #expect(c.appearance == "dark")
    #expect(c.allowMcpActions == true)
    #expect(c.provider == "claude")           // untouched default
}

@Test func configFullRoundTripPinsCodingKeys() throws {
    var c = AdvisorConfig()
    c.triggerSensitivity = "eager"
    c.triggers = .init(question: false, context: true, factcheck: false)
    c.allowMcpActions = true
    c.provider = "codex"
    c.model = "gpt-5"
    c.effort = "low"
    c.sttLocale = "en_GB"
    c.authMode = "apiKey"
    c.appearance = "dark"
    c.sessionDir = "/tmp/notes"
    c.logTranscriptText = true
    c.readableFolders = ["/Users/x/Documents", "~/Library/Mobile Documents"]
    let decoded = try JSONDecoder().decode(
        AdvisorConfig.self, from: JSONEncoder().encode(c))
    #expect(decoded == c) // any dropped CodingKey breaks equality
}

// Defaults shared with the sidecar (sidecar/src/config.ts) — pin them so a
// Swift-side change can't silently drift from the sidecar contract.
@Test func configDefaultsMatchSidecarContract() {
    let d = AdvisorConfig()
    #expect(d.provider == "claude")
    #expect(d.model == "")
    #expect(d.effort == "")
    #expect(d.triggerSensitivity == "balanced")
    #expect(d.allowMcpActions == false)
    #expect(d.readableFolders == [])
    #expect(d.triggers == AdvisorConfig.Triggers(question: true, context: true, factcheck: true))
}

// The sidecar drops an unknown effort level to "" (inherit); the app must agree,
// or the picker shows a blank selection while Default is what actually runs.
@Test func configDecodeDropsUnknownEffortToDefault() throws {
    let unknown = try JSONDecoder().decode(AdvisorConfig.self, from: Data(#"{"effort":"ultra"}"#.utf8))
    #expect(unknown.effort == "")
    let known = try JSONDecoder().decode(AdvisorConfig.self, from: Data(#"{"effort":"max"}"#.utf8))
    #expect(known.effort == "max")
}

// A readableFolders value of the wrong shape must not fail the whole decode:
// load() would fall back to the defaults and the next save() would wipe every
// setting (issue #65). It gives no readable folder, which fails closed.
@Test func configDecodeToleratesMalformedReadableFolders() throws {
    let json = Data(#"{"provider":"codex","readableFolders":"/Users/x"}"#.utf8)
    let c = try JSONDecoder().decode(AdvisorConfig.self, from: json)
    #expect(c.provider == "codex")
    #expect(c.readableFolders == [])
}

private func tempConfigFile() -> (dir: URL, file: URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (dir, dir.appendingPathComponent("config.json"))
}

private func rawJSON(_ file: URL) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
}

/// A JSON value as sorted JSON text, so `1` and `true` compare unequal.
private func canonical(_ json: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: [json], options: [.sortedKeys])
}

// The Preferences window writes only the settings that the user changed. Its
// copy can be older than the file (a hand edit, a context saved from the
// recording window, a Files-tab edit), and a save of the whole copy wrote the
// old values over the file's (code review 2026-11-10). Every other key stays
// as the file holds it, including a key that this version does not know and a
// value that the decode drops.
@Test func preferencesSaveWritesOnlyTheChangedSettings() throws {
    let (dir, file) = tempConfigFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    var disk = AdvisorConfig()
    disk.triggerSensitivity = "eager"
    disk.contexts = [SavedContext(name: "Standup", text: "Daily standup")]
    disk.readableFolders = ["~/Notes"]
    disk.save(to: file)
    var raw = try rawJSON(file)
    raw["effort"] = "ultra"
    raw["futureKey"] = ["a": [1, true, NSNull()]]
    try JSONSerialization.data(withJSONObject: raw).write(to: file)
    let window = AdvisorConfig() // the window's older copy
    var edited = window
    edited.appearance = "dark"
    #expect(edited.saveChanges(from: window, to: file))
    var expected = raw
    expected["appearance"] = "dark"
    #expect(try canonical(rawJSON(file)) == canonical(expected))
}

// A copy with no change writes nothing, and the window has no control for the
// readable folders: a difference there is never written.
@Test func preferencesSaveWithNoChangeWritesNothing() {
    let (dir, file) = tempConfigFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    let window = AdvisorConfig()
    var foldersOnly = window
    foldersOnly.readableFolders = ["~/Private"]
    #expect(window.saveChanges(from: window, to: file))
    #expect(foldersOnly.saveChanges(from: window, to: file))
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

// The window never writes the readable folders, or a folder that the user
// removed from the file comes back.
@Test func preferencesSaveKeepsTheReadableFoldersOnDisk() throws {
    let (dir, file) = tempConfigFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    // The window opened with two folders; the user then removed one by hand.
    var window = AdvisorConfig()
    window.readableFolders = ["~/Notes", "~/Private"]
    var disk = window
    disk.readableFolders = ["~/Notes"]
    disk.save(to: file)
    var edited = window
    edited.appearance = "dark" // the change in the window that triggers its save
    edited.readableFolders = []
    #expect(edited.saveChanges(from: window, to: file))
    let saved = AdvisorConfig.load(from: file)
    #expect(saved.readableFolders == ["~/Notes"])
    #expect(saved.appearance == "dark")
}

// A file that does not decode (a hand edit cut off before its end, or a value
// of the wrong type) is left as it is: the window's copy is not the file's.
// (The decoder accepts trailing commas, so they are no such case.)
@Test func preferencesSaveLeavesAnUndecodableFileAsItIs() throws {
    let (dir, file) = tempConfigFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let window = AdvisorConfig()
    var edited = window
    edited.appearance = "dark"
    for body in [#"{"readableFolders":["~/Notes"]"#, #"{"model":5,"readableFolders":["~/Notes"]}"#] {
        let broken = Data(body.utf8)
        try broken.write(to: file)
        #expect(!edited.saveChanges(from: window, to: file), "\(body)")
        #expect(try Data(contentsOf: file) == broken, "\(body)")
    }
}

// A file that exists but cannot be read is not a missing file: the save must
// not write a new file over it.
@Test func preferencesSaveLeavesAnUnreadableFileAsItIs() throws {
    let (dir, file) = tempConfigFile()
    var disk = AdvisorConfig()
    disk.readableFolders = ["~/Notes"]
    disk.save(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try? FileManager.default.removeItem(at: dir)
    }
    #expect((try? Data(contentsOf: file)) == nil) // the precondition: unreadable
    var edited = AdvisorConfig()
    edited.appearance = "dark"
    #expect(!edited.saveChanges(from: AdvisorConfig(), to: file))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    #expect(AdvisorConfig.load(from: file) == disk)
}

// With no file, the save makes one that holds only the change.
@Test func preferencesSaveWithNoFileWritesOnlyTheChange() throws {
    let (dir, file) = tempConfigFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    var window = AdvisorConfig()
    window.readableFolders = ["~/Private"]
    var edited = window
    edited.appearance = "dark"
    #expect(edited.saveChanges(from: window, to: file))
    #expect(try canonical(rawJSON(file)) == canonical(["appearance": "dark"]))
}

// A view that reloads on advisorConfigChanged keeps what it shows when the
// file cannot be used. The defaults would reset the appearance, the triggers
// and the libraries, and the Files tab posts the notice for such a file.
@Test func loadIfUsableGivesNothingForAnUnusableFile() throws {
    let (dir, file) = tempConfigFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(AdvisorConfig.loadIfUsable(from: file) == AdvisorConfig())
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for body in [#"{"appearance":"dark""#, #"{"appearance":"dark","model":5}"#] {
        try Data(body.utf8).write(to: file)
        #expect(AdvisorConfig.loadIfUsable(from: file) == nil, "\(body)")
    }
    var disk = AdvisorConfig()
    disk.appearance = "dark"
    disk.save(to: file)
    #expect(AdvisorConfig.loadIfUsable(from: file) == disk)
}

// The window's link to the file (`PreferencesFile`). Opening the window and a
// reload write nothing when every change is in the file. Each test drives a
// reload as the window does: `reload(keeping:)`, then `commit` of what it
// gives. (A test macro cannot call a mutating method, so each result is taken
// first.)
@Test func preferencesFileOpeningWritesNothing() throws {
    let (dir, file) = tempConfigFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    var window = PreferencesFile(url: file)
    #expect(window.saved == AdvisorConfig())
    let reloaded = window.reload(keeping: window.saved)
    let shown = try #require(reloaded)
    let wrote = window.commit(shown)
    #expect(shown == AdvisorConfig())
    #expect(!wrote)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    var disk = AdvisorConfig()
    disk.appearance = "dark"
    disk.save(to: file)
    let before = try Data(contentsOf: file)
    window = PreferencesFile(url: file)
    #expect(window.saved == disk)
    let reloadedDisk = window.reload(keeping: window.saved)
    let shownDisk = try #require(reloadedDisk)
    let wroteDisk = window.commit(shownDisk)
    #expect(shownDisk == disk)
    #expect(!wroteDisk)
    #expect(try Data(contentsOf: file) == before)
}

// A context saved from the recording window, or a hand edit, after the window
// read the file: the next change in the window writes only itself.
@Test func preferencesFileKeepsWhatChangedOnDiskSinceItsRead() throws {
    let (dir, file) = tempConfigFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    AdvisorConfig().save(to: file)
    var window = PreferencesFile(url: file)
    var shown = window.saved
    var newer = shown
    newer.contexts = [SavedContext(name: "Standup", text: "Daily standup")]
    newer.triggerSensitivity = "eager"
    newer.save(to: file)
    shown.appearance = "dark"
    let wrote = window.commit(shown)
    #expect(wrote)
    let saved = AdvisorConfig.load(from: file)
    #expect(saved.contexts == newer.contexts)
    #expect(saved.triggerSensitivity == "eager")
    #expect(saved.appearance == "dark")
}

// A change that the window wrote is not written again: another writer can
// change the same setting later, and the window's next change is another one.
@Test func preferencesFileWritesEachChangeOnce() throws {
    let (dir, file) = tempConfigFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    AdvisorConfig().save(to: file)
    var window = PreferencesFile(url: file)
    var shown = window.saved
    shown.appearance = "dark"
    let first = window.commit(shown)
    let again = window.commit(shown)
    #expect(first)
    #expect(!again)
    var other = AdvisorConfig.load(from: file)
    other.appearance = "light"
    other.save(to: file)
    shown.triggerSensitivity = "eager"
    let next = window.commit(shown)
    #expect(next)
    let saved = AdvisorConfig.load(from: file)
    #expect(saved.appearance == "light")
    #expect(saved.triggerSensitivity == "eager")
}

// A file that cannot be used: the window writes nothing. After the user
// corrects the file, a reload takes it, and the next change writes only
// itself, not the defaults that the window held (code review 2026-11-10).
@Test func preferencesFileAfterACorrectionWritesOnlyTheChange() throws {
    let (dir, file) = tempConfigFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let broken = Data(#"{"appearance":"dark""#.utf8)
    try broken.write(to: file)
    var window = PreferencesFile(url: file)
    #expect(window.unusable)
    let held = window.saved // the defaults, which the locked controls show
    let failedReload = window.reload(keeping: held)
    #expect(failedReload == nil)
    #expect(try Data(contentsOf: file) == broken)
    // The user corrects the file.
    var fixed = AdvisorConfig()
    fixed.triggerSensitivity = "eager"
    fixed.contexts = [SavedContext(name: "Standup", text: "Daily standup")]
    fixed.save(to: file)
    let reloaded = window.reload(keeping: held)
    let disk = try #require(reloaded)
    let wroteReload = window.commit(disk)
    #expect(!window.unusable)
    #expect(disk == fixed)
    #expect(!wroteReload)
    var edited = disk
    edited.appearance = "dark"
    let wrote = window.commit(edited)
    #expect(wrote)
    let saved = AdvisorConfig.load(from: file)
    #expect(saved.triggerSensitivity == "eager")
    #expect(saved.contexts == fixed.contexts)
    #expect(saved.appearance == "dark")
}

// After the file is deleted, a reload shows the defaults and writes nothing.
// The next change makes a file that holds only that change, not the copy that
// the window held before.
@Test func preferencesFileReloadAfterTheFileIsDeleted() throws {
    let (dir, file) = tempConfigFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    var disk = AdvisorConfig()
    disk.appearance = "dark"
    disk.contexts = [SavedContext(name: "Standup", text: "Daily standup")]
    disk.save(to: file)
    var window = PreferencesFile(url: file)
    #expect(window.saved == disk)
    try FileManager.default.removeItem(at: file)
    let reloaded = window.reload(keeping: window.saved)
    #expect(reloaded == AdvisorConfig())
    #expect(!FileManager.default.fileExists(atPath: file.path))
    var edited = AdvisorConfig()
    edited.triggerSensitivity = "eager"
    let wrote = window.commit(edited)
    #expect(wrote)
    #expect(try canonical(rawJSON(file)) == canonical(["triggerSensitivity": "eager"]))
}

// A change that cannot be written is written with the next change.
@Test func preferencesFileWritesAFailedChangeWithTheNextOne() throws {
    let (dir, file) = tempConfigFile()
    AdvisorConfig().save(to: file)
    var window = PreferencesFile(url: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }
    var shown = window.saved
    shown.appearance = "dark"
    let failed = window.commit(shown)
    #expect(!failed)
    #expect(window.notSaved)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
    shown.triggerSensitivity = "eager"
    let wrote = window.commit(shown)
    #expect(wrote)
    #expect(!window.notSaved)
    let saved = AdvisorConfig.load(from: file)
    #expect(saved.appearance == "dark")
    #expect(saved.triggerSensitivity == "eager")
}

// A change that could not be written stays in the window across a reload,
// over the file's newer settings, and the reload writes it again. The notice
// stays until a write succeeds. Before, the reload showed the file's value,
// and its `commit` of that value cleared the notice (code review 2026-11-11).
@Test func preferencesFileKeepsAFailedChangeAcrossAReload() throws {
    let (dir, file) = tempConfigFile()
    AdvisorConfig().save(to: file)
    var window = PreferencesFile(url: file)
    let readOnly = { try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path) }
    let writable = { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
    try readOnly()
    defer {
        try? writable()
        try? FileManager.default.removeItem(at: dir)
    }
    var shown = window.saved
    shown.appearance = "dark"
    let failed = window.commit(shown)
    #expect(!failed)
    #expect(window.notSaved)
    // Another writer saves a context while the folder is writable for it.
    try writable()
    var other = AdvisorConfig.load(from: file)
    other.contexts = [SavedContext(name: "Standup", text: "Daily standup")]
    other.save(to: file)
    try readOnly()
    let reloaded = window.reload(keeping: shown)
    let kept = try #require(reloaded)
    let failedAgain = window.commit(kept)
    #expect(kept.appearance == "dark")
    #expect(kept.contexts == other.contexts)
    #expect(!failedAgain)
    #expect(window.notSaved)
    // The folder is writable again: the next reload writes the change.
    try writable()
    let reloadedAgain = window.reload(keeping: kept)
    let keptAgain = try #require(reloadedAgain)
    let wrote = window.commit(keptAgain)
    #expect(keptAgain == kept)
    #expect(wrote)
    #expect(!window.notSaved)
    let saved = AdvisorConfig.load(from: file)
    #expect(saved.appearance == "dark")
    #expect(saved.contexts == other.contexts)
}

// A change whose write finds the file broken stays in the window. After the
// user corrects the file, the reload writes it over the corrected file. Before,
// the reload showed the file's value, and the change was lost with no notice
// (code review 2026-11-11).
@Test func preferencesFileKeepsAChangeThatFindsTheFileUnusable() throws {
    let (dir, file) = tempConfigFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    AdvisorConfig().save(to: file)
    var window = PreferencesFile(url: file)
    var shown = window.saved
    shown.appearance = "dark"
    let broken = Data(#"{"appearance":"light",}"#.utf8)
    try broken.write(to: file)
    let failed = window.commit(shown)
    #expect(!failed)
    #expect(window.unusable)
    #expect(window.notSaved)
    #expect(try Data(contentsOf: file) == broken)
    let stillBroken = window.reload(keeping: shown)
    #expect(stillBroken == nil)
    #expect(window.notSaved)
    // The user corrects the file.
    var fixed = AdvisorConfig()
    fixed.appearance = "light"
    fixed.triggerSensitivity = "eager"
    fixed.save(to: file)
    let reloaded = window.reload(keeping: shown)
    let kept = try #require(reloaded)
    let wrote = window.commit(kept)
    #expect(kept.appearance == "dark")
    #expect(kept.triggerSensitivity == "eager")
    #expect(wrote)
    #expect(!window.unusable)
    #expect(!window.notSaved)
    let saved = AdvisorConfig.load(from: file)
    #expect(saved.appearance == "dark")
    #expect(saved.triggerSensitivity == "eager")
}

// The provider picker clears the model only for a provider that the user
// picks. A provider that a reload sets keeps the file's model, so the reload
// writes nothing (code review 2026-11-10).
@Test func agentBackendClearsTheModelOnlyForAPickedProvider() {
    final class Box { var provider = "claude"; var model = "claude-opus" }
    let box = Box()
    let provider = Binding(get: { box.provider }, set: { box.provider = $0 })
    let model = Binding(get: { box.model }, set: { box.model = $0 })
    let picked = AgentBackendView.picked(provider: provider, clearing: model)
    picked.wrappedValue = "claude" // the same provider again
    #expect(box.model == "claude-opus")
    picked.wrappedValue = "codex"
    #expect(box.provider == "codex")
    #expect(box.model == "")
    // A reload sets the provider and the model through the plain bindings.
    provider.wrappedValue = "claude"
    model.wrappedValue = "claude-sonnet"
    #expect(picked.wrappedValue == "claude")
    #expect(box.model == "claude-sonnet")
}

// The user undoes a change that could not be written: the window and the file
// agree again, so the notice goes.
@Test func preferencesFileClearsTheNoticeWhenTheFailedChangeIsUndone() throws {
    let (dir, file) = tempConfigFile()
    AdvisorConfig().save(to: file)
    var window = PreferencesFile(url: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }
    var shown = window.saved
    shown.appearance = "dark"
    let failed = window.commit(shown)
    #expect(!failed)
    #expect(window.notSaved)
    let undone = window.commit(window.saved)
    #expect(!undone)
    #expect(!window.notSaved)
}

// The sidecar keeps the string entries of a mixed list (mergeConfig). The app
// must keep the same ones, or its next save wipes the folders that the
// sidecar reads.
@Test func configDecodeKeepsTheStringEntriesOfReadableFolders() throws {
    let json = Data(#"{"readableFolders":["~/Notes",5,null,"/Users/x/dev"]}"#.utf8)
    let c = try JSONDecoder().decode(AdvisorConfig.self, from: json)
    #expect(c.readableFolders == ["~/Notes", "/Users/x/dev"])
}

// MARK: load() keeps the keys that decode (issue #137)

// A reader such as the session folder must not take every default because one
// other key has the wrong type: a recording then went to the default folder.
@Test func loadKeepsTheKeysThatDecodeWhenOneKeyHasTheWrongType() throws {
    let (dir, file) = tempConfigFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(#"{"allowMcpActions":"true","sessionDir":"/Notes/Advisor","provider":"codex","sttLocale":"en_GB"}"#.utf8)
        .write(to: file)
    let config = AdvisorConfig.load(from: file)
    #expect(config.sessionDir == "/Notes/Advisor")
    #expect(config.provider == "codex")
    #expect(config.sttLocale == "en_GB")
    #expect(config.allowMcpActions == false, "the key that does not decode keeps its default")
}

// A library that is not a list gives an empty library, and the other keys stay.
@Test func loadGivesAnEmptyLibraryForALibraryThatIsNotAList() throws {
    let (dir, file) = tempConfigFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(#"{"contexts":"none","sessionDir":"/Notes/Advisor","triggers":{"question":false,"context":true,"factcheck":true}}"#.utf8)
        .write(to: file)
    let config = AdvisorConfig.load(from: file)
    #expect(config.contexts.isEmpty)
    #expect(config.sessionDir == "/Notes/Advisor")
    #expect(config.triggers.question == false)
}

// The tolerant read is for readers only. The file still counts as unusable
// for a save, so a default in place of the bad value never reaches the file.
@Test func aFileWithOneBadKeyStaysUnusableForASave() throws {
    let (dir, file) = tempConfigFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let broken = Data(#"{"allowMcpActions":"true","sessionDir":"/Notes/Advisor"}"#.utf8)
    try broken.write(to: file)
    guard case .unusable = AdvisorConfig.fileState(at: file) else {
        Issue.record("the file must stay unusable")
        return
    }
    #expect(AdvisorConfig.loadIfUsable(from: file) == nil)
    var edited = AdvisorConfig.load(from: file)
    let window = edited
    edited.appearance = "dark"
    #expect(!edited.saveChanges(from: window, to: file))
    #expect(AdvisorConfig.saveContext(named: "a", text: "b", at: file) == nil)
    #expect(try Data(contentsOf: file) == broken)
}

// Text that is not JSON, or not a JSON object, has no keys to keep.
@Test func loadGivesTheDefaultsForAFileThatIsNotAJSONObject() throws {
    let (dir, file) = tempConfigFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for body in [#"{"sessionDir":"/Notes/Advisor""#, #"["sessionDir"]"#, ""] {
        try Data(body.utf8).write(to: file)
        #expect(AdvisorConfig.load(from: file) == AdvisorConfig(), "\(body)")
    }
}

// A number that JSON cannot hold (it parses to infinity) must not stop the
// app: a re-serialise of such a value raises an exception that Swift cannot
// catch (code review 2026-11-15).
@Test func loadDoesNotFailOnANumberOutOfRange() throws {
    let (dir, file) = tempConfigFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for body in [#"{"sessionDir":-1e999}"#, #"{"zzz":-1e999,"allowMcpActions":"true","provider":"codex"}"#] {
        try Data(body.utf8).write(to: file)
        #expect(AdvisorConfig.load(from: file).sessionDir == "", "\(body)")
    }
    // The second file: the keys that decode are kept, also beside such a number.
    #expect(AdvisorConfig.load(from: file).provider == "codex")
}

// One bad entry in a library drops that entry only: the reader filters the
// tags of the notes by the library, so an empty library would hide them all.
@Test func loadKeepsTheGoodEntriesOfALibraryWithABadEntry() throws {
    let (dir, file) = tempConfigFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var disk = AdvisorConfig()
    disk.tags = [SavedTag(name: "work", colorHex: "#112233")]
    disk.contexts = [SavedContext(name: "standup", text: "the team")]
    disk.save(to: file)
    var json = try rawJSON(file)
    json["tags"] = (json["tags"] as! [Any]) + [["name": 5]]
    json["contexts"] = [["name": 5]] + (json["contexts"] as! [Any])
    try JSONSerialization.data(withJSONObject: json).write(to: file)
    guard case .unusable = AdvisorConfig.fileState(at: file) else {
        Issue.record("the file must stay unusable for a save")
        return
    }
    let config = AdvisorConfig.load(from: file)
    #expect(config.tags == disk.tags)
    #expect(config.contexts == disk.contexts)
}

// The session folder and the other app-side keys do not depend on how the
// sidecar reads the file: a trailing comma, which the sidecar refuses, beside
// a key that does not decode still gives the file's session folder.
@Test func loadKeepsTheAppSideKeysOfAFileThatTheSidecarRefuses() throws {
    let (dir, file) = tempConfigFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(#"{"sessionDir":"/Notes/Advisor","allowMcpActions":"true",}"#.utf8).write(to: file)
    #expect(AdvisorConfig.load(from: file).sessionDir == "/Notes/Advisor")
}

// The API key that the app gives the sidecar must match the provider that the
// sidecar runs (code review 2026-11-15).
@Test func theSidecarKeyFollowsTheSidecarsReadOfTheFile() throws {
    let (dir, file) = tempConfigFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(AdvisorConfig.loadForSidecarKey(from: file) == AdvisorConfig(), "no file")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let key = { (body: String) -> [String] in
        try Data(body.utf8).write(to: file)
        let config = AdvisorConfig.loadForSidecarKey(from: file)
        return [config.provider, config.authMode]
    }
    // A file that decodes as a whole.
    #expect(try key(#"{"provider":"codex","authMode":"apiKey"}"#) == ["codex", "apiKey"])
    // A key that does not decode: the sidecar merges the other keys, and so
    // does the app. A provider of the wrong type is the default on both sides.
    #expect(try key(#"{"provider":"codex","authMode":"apiKey","allowMcpActions":"true"}"#) == ["codex", "apiKey"])
    #expect(try key(#"{"provider":5,"authMode":"apiKey"}"#) == ["claude", "apiKey"])
    // Such a key in a file that the sidecar refuses (a trailing comma) or
    // reads to other values (two equal keys), and a file that is cut off: no key.
    #expect(try key(#"{"provider":"codex","authMode":"apiKey","allowMcpActions":"true",}"#) == ["claude", "subscription"])
    #expect(try key(#"{"provider":"claude","provider":"codex","authMode":"apiKey","model":5}"#) == ["claude", "subscription"])
    #expect(try key(#"{"provider":"codex","authMode":"apiKey""#) == ["claude", "subscription"])
    // As before issue #137: a trailing comma in a file that decodes. The
    // sidecar runs its default provider, and the key for it still arrives.
    #expect(try key(#"{"authMode":"apiKey",}"#) == ["claude", "apiKey"])
}

// The sidecar merges each trigger flag, so the reader keeps the flags that
// the file gives when another key does not decode.
@Test func loadKeepsTheTriggerFlagsThatTheFileGives() throws {
    let (dir, file) = tempConfigFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(#"{"triggers":{"question":false,"context":"no"},"allowMcpActions":"true"}"#.utf8).write(to: file)
    let triggers = AdvisorConfig.load(from: file).triggers
    #expect(triggers.question == false)
    #expect(triggers.context == true, "a flag of the wrong type keeps its default")
    #expect(triggers.factcheck == true)
}
