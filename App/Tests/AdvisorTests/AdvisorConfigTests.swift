import Foundation
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

// The Preferences window saves its whole copy of the config, and it has no
// control for the readable folders. Its save must keep the file's list, or a
// folder that the user removed from the file comes back.
@Test func preferencesSaveKeepsTheReadableFoldersOnDisk() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("config.json")
    // The window opened with two folders; the user then removed one by hand.
    var window = AdvisorConfig()
    window.readableFolders = ["~/Notes", "~/Private"]
    var disk = window
    disk.readableFolders = ["~/Notes"]
    disk.save(to: file)
    window.appearance = "dark" // the change in the window that triggers its save
    window.saveFromPreferences(to: file)
    let saved = AdvisorConfig.load(from: file)
    #expect(saved.readableFolders == ["~/Notes"])
    #expect(saved.appearance == "dark")
}

// A file that does not decode (a hand edit cut off before its end) has no
// list that the save could keep. The save leaves the file as it is: the
// window's copy could add back a removed folder, and the defaults would delete
// the list. (The decoder accepts trailing commas, so they are no such case.)
@Test func preferencesSaveLeavesAnUndecodableFileAsItIs() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("config.json")
    let broken = Data(#"{"readableFolders":["~/Notes"]"#.utf8)
    try broken.write(to: file)
    var window = AdvisorConfig()
    window.readableFolders = ["~/Notes", "~/Private"]
    window.saveFromPreferences(to: file)
    #expect(try Data(contentsOf: file) == broken)
}

// A file that exists but cannot be read is not a missing file: the save must
// not write an empty list over it.
@Test func preferencesSaveLeavesAnUnreadableFileAsItIs() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("config.json")
    var disk = AdvisorConfig()
    disk.readableFolders = ["~/Notes"]
    disk.save(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try? FileManager.default.removeItem(at: dir)
    }
    #expect((try? Data(contentsOf: file)) == nil) // the precondition: unreadable
    AdvisorConfig().saveFromPreferences(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    #expect(AdvisorConfig.load(from: file).readableFolders == ["~/Notes"])
}

// With no file there is no list, so the save writes none, whatever the
// window's copy holds.
@Test func preferencesSaveWithNoFileWritesNoReadableFolders() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("config.json")
    var window = AdvisorConfig()
    window.readableFolders = ["~/Private"]
    window.appearance = "dark"
    window.saveFromPreferences(to: file)
    let saved = AdvisorConfig.load(from: file)
    #expect(saved.readableFolders == [])
    #expect(saved.appearance == "dark")
}

// The sidecar keeps the string entries of a mixed list (mergeConfig). The app
// must keep the same ones, or its next save wipes the folders that the
// sidecar reads.
@Test func configDecodeKeepsTheStringEntriesOfReadableFolders() throws {
    let json = Data(#"{"readableFolders":["~/Notes",5,null,"/Users/x/dev"]}"#.utf8)
    let c = try JSONDecoder().decode(AdvisorConfig.self, from: json)
    #expect(c.readableFolders == ["~/Notes", "/Users/x/dev"])
}
