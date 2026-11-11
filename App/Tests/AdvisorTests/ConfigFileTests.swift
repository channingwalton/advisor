import Foundation
import Testing

@testable import Advisor

// config.json as the sidecar reads it (`ConfigFile.readsAsTheSidecar`). Swift's
// parser takes some JSON that Node's `JSON.parse` refuses or reads to other
// values (checked 2026-11-10). The app must not show such a file's settings,
// such as the readable folders, as the ones in use.

@Test func configFileRefusesJSONThatTheSidecarReadsInAnotherWay() throws {
    let differs = [
        "\u{FEFF}{\"readableFolders\":[\"~/Notes\"]}",           // a byte-order mark
        #"{"readableFolders":["~/Notes",]}"#,                    // a trailing comma in a list
        #"{"readableFolders":["~/Notes"],}"#,                    // a trailing comma in an object
        #"{"triggers":{"question":true,},"model":""}"#,          // in a nested object
        #"{"readableFolders":["~/A"],"readableFolders":["~/B"]}"#, // Swift keeps ~/A, Node ~/B
        #"{"triggers":{"question":true,"question":false}}"#,     // a nested duplicate
        #"{"readableFolders":["~/A"],"readableFold\u0065rs":["~/B"]}"#, // the same key, escaped
    ]
    for body in differs {
        let data = Data(body.utf8)
        #expect((try? JSONSerialization.jsonObject(with: data)) != nil, "precondition: Swift reads \(body)")
        #expect(!ConfigFile.readsAsTheSidecar(data), "\(body)")
    }
    // UTF-16 and UTF-32, which the sidecar reads as UTF-8.
    let body = #"{"readableFolders":["~/Notes"]}"#
    for encoding in [String.Encoding.utf16, .utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian] {
        let data = try #require(body.data(using: encoding))
        #expect((try? JSONSerialization.jsonObject(with: data)) != nil, "precondition: Swift reads \(encoding)")
        #expect(!ConfigFile.readsAsTheSidecar(data), "\(encoding)")
    }
}

@Test func configFileTakesJSONThatBothParsersReadAlike() {
    let alike = [
        #"{}"#,
        #"{"readableFolders":[]}"#,
        #"{"a":"x,]","b":"},{\"a\":1,","c":["a","a"],"d":{"a":1},"e":{"a":2}}"#,
        #"{"a":"\\","b":[{"a":1},{"a":1}],"c":"a"}"#,
        "{\"Caf\u{E9}\":1,\"Cafe\u{301}\":2}",                  // two keys for both parsers: NFC and NFD
        "{\n  \"appearance\" : \"dark\",\n  \"readableFolders\" : [\n    \"~/Caf\u{E9} \u{2603}\"\n  ]\n}",
    ]
    for body in alike {
        #expect(ConfigFile.readsAsTheSidecar(Data(body.utf8)), "\(body)")
    }
    // What the app writes.
    var config = AdvisorConfig()
    config.readableFolders = ["~/Notes"]
    config.contexts = [SavedContext(name: "Standup", text: "Daily, \"standup\"]")]
    let encoded = try? JSONEncoder().encode(config)
    #expect(encoded.map(ConfigFile.readsAsTheSidecar) == true)
}

// Each reader of the file treats such a file as one that cannot be used.
@Test func aFileThatTheSidecarReadsInAnotherWayCannotBeUsed() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("config.json")
    let body = Data(#"{"appearance":"dark","readableFolders":["~/Notes",]}"#.utf8)
    try body.write(to: file)
    #expect(ReadableFolders.load(from: file) == nil)
    #expect(ReadableFolders.remove("~/Notes", at: file) == .unusable)
    #expect(AdvisorConfig.loadIfUsable(from: file) == nil)
    guard case .unusable = AdvisorConfig.fileState(at: file) else {
        Issue.record("fileState should refuse the file")
        return
    }
    var edited = AdvisorConfig()
    edited.appearance = "light"
    #expect(!edited.saveChanges(from: AdvisorConfig(), to: file))
    #expect(AdvisorConfig.saveContext(named: "Standup", text: "Daily", at: file) == nil)
    #expect(try Data(contentsOf: file) == body)
}

// The recording window's Save… applies to the library that the file holds at
// that moment, not to the window's copy: a context added since (by hand, or
// in Preferences while the window kept an older list) stays. Only `contexts`
// is written.
@Test func saveContextAppliesToTheFilesLibraryNow() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("config.json")
    #expect(AdvisorConfig.saveContext(named: "Standup", text: "Daily", at: file)?.map(\.name) == ["Standup"])
    var disk = AdvisorConfig.load(from: file)
    disk.contexts.append(SavedContext(name: "Retro", text: "Fortnightly"))
    disk.readableFolders = ["~/Notes"]
    disk.save(to: file)
    var raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    raw["futureKey"] = ["a": 1]
    try JSONSerialization.data(withJSONObject: raw).write(to: file)
    let saved = AdvisorConfig.saveContext(named: "Standup", text: "Weekly", at: file)
    #expect(saved?.map(\.name) == ["Standup", "Retro"])
    #expect(saved?.first?.text == "Weekly")
    let after = AdvisorConfig.load(from: file)
    #expect(after.contexts == saved)
    #expect(after.readableFolders == ["~/Notes"])
    let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(json["futureKey"] as? [String: Int] == ["a": 1])
}

// Swift's dictionary merges two keys that differ only in normal form, which the
// file and the sidecar keep apart. A write of the merged object would delete
// one, so the file counts as unusable and no edit writes it.
@Test func aFileWithKeysThatSwiftMergesCannotBeUsed() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("config.json")
    let body = Data("{\"Caf\u{E9}\":1,\"Cafe\u{301}\":2,\"readableFolders\":[\"~/Notes\"]}".utf8)
    try body.write(to: file)
    guard case .unusable = ConfigFile.read(at: file) else {
        Issue.record("read should refuse the file")
        return
    }
    #expect(ReadableFolders.add(["/Users/x/Work"], at: file) == .unusable)
    #expect(try Data(contentsOf: file) == body)
}
