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
