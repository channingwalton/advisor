import Foundation
import Testing

@testable import Advisor

// The NDJSON protocol is written down twice — `Inbound`/`Outbound` in
// sidecar/src/protocol.ts and string-keyed dictionaries in SidecarManager —
// over a pipe neither side checks the shape of, so a field renamed on one side
// showed up as empty cards or ignored frames with both suites green.
// `protocol/examples.json` is the one set of frames both suites hold their side
// to (issue #97; the sidecar's half is protocol.test.ts). Here SidecarManager's
// sends are held to the app → sidecar examples — every field a send carries is
// in its example with the same JSON kind, and between them the sends cover the
// example's every field — and the sidecar → app examples are fed through its
// inbound handler, each field checked to land where the app reads it.

private typealias Frame = [String: Any]

/// One direction of the examples: the frames, and per type the fields a frame
/// may leave out (protocol.test.ts holds that map to the types' `?`).
private struct Direction {
    let frames: [Frame]
    let optional: [String: [String]]

    init(_ raw: Any?) throws {
        let object = try #require(raw as? [String: Any])
        frames = try #require(object["frames"] as? [Frame])
        optional = try #require(object["optional"] as? [String: [String]])
    }

    func frame(_ type: String) throws -> Frame {
        try #require(frames.first { $0["type"] as? String == type }, "no \(type) example")
    }

    /// The fields every frame of `type` must carry.
    func required(_ type: String) throws -> Set<String> {
        Set(try frame(type).keys).subtracting(optional[type] ?? [])
    }
}

private struct Examples {
    let appToSidecar: Direction
    let sidecarToApp: Direction

    static func load() throws -> Examples {
        let url = repoRoot.appendingPathComponent("protocol/examples.json")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return Examples(
            appToSidecar: try Direction(root["appToSidecar"]), sidecarToApp: try Direction(root["sidecarToApp"]))
    }
}

/// The JSON kind of a decoded value, booleans told apart from numbers.
private func kind(_ value: Any) -> String {
    switch value {
    case let number as NSNumber:
        return CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : "number"
    case is String: return "string"
    case is [Any]: return "array"
    case is [String: Any]: return "object"
    default: return "null"
    }
}

/// A SidecarManager over a shell child that records its stdin, so what the
/// manager sends can be read back (as SidecarAuthenticationTests does).
@MainActor
private final class Harness {
    let store = TranscriptStore()
    private var children: [Process] = []
    private var outputWriters: [FileHandle] = []
    private let inputFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-protocol-test-\(UUID().uuidString)")

    lazy var manager = SidecarManager(
        store: store,
        loadConfig: { AdvisorConfig() },
        readKey: { _ in nil },
        launchProcess: { [unowned self] process in
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [
                "-c", "while IFS= read -r line; do printf '%s\\n' \"$line\" >> \"$ADVISOR_TEST_INPUT\"; done",
            ]
            var environment = process.environment ?? [:]
            environment["ADVISOR_TEST_INPUT"] = self.inputFile.path
            process.environment = environment
            // Hold the child's stdout open past its exit, as the auth harness does.
            let outputPipe = process.standardOutput as! Pipe
            self.outputWriters.append(
                FileHandle(
                    fileDescriptor: dup(outputPipe.fileHandleForWriting.fileDescriptor), closeOnDealloc: true))
            try process.run()
            self.children.append(process)
        },
        environment: [:]
    )

    /// The frames the child has recorded so far.
    func sent() -> [Frame] {
        guard let data = try? Data(contentsOf: inputFile) else { return [] }
        return SidecarManager.ndjsonFrames(data).frames.compactMap {
            try? JSONSerialization.jsonObject(with: $0) as? Frame
        }
    }

    func close() {
        manager.stop()
        for child in children {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        for output in outputWriters { try? output.close() }
        try? FileManager.default.removeItem(at: inputFile)
    }
}

/// Polls `predicate` every 5 ms, for up to 2 s.
@MainActor
private func waitFor(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return predicate()
}

// MARK: app → sidecar

/// Notes typed before Listen follow `session_start`, which clears the
/// sidecar's transcript, so the agents read them (issue #104).
@MainActor
@Test func sessionStartSendsTheNotesTypedBeforeIt() async throws {
    let h = Harness()
    defer { h.close() }
    h.manager.start()
    let note = EditorialNote(id: UUID(), time: Date(), text: "Bob is the CFO")

    h.manager.sendSessionStart("0F3B5C2A-7D1E-4F8A-9B6C-2E4D8A1F3C5B", notes: [note])

    #expect(await waitFor { h.sent().count == 2 })
    let sent = h.sent()
    #expect(sent.map { $0["type"] as? String } == ["session_start", "note"])
    #expect(sent.last?["id"] as? String == note.id.uuidString)
}

/// Every preference edit passes the "Include transcript text in the log"
/// value on. With no sidecar running there is no one to tell — the next one
/// reads config.json — so nothing is sent and no dropped message is reported.
@MainActor
@Test func logTranscriptTextIsSentOnlyToARunningSidecar() async throws {
    let h = Harness()
    defer { h.close() }
    h.manager.sendLogTranscriptText(true)
    #expect(!h.store.status.contains("dropped"))
    h.manager.start()
    h.manager.sendLogTranscriptText(true)
    h.manager.sendLogTranscriptText(false)
    h.manager.sendSessionEnd() // a marker: once it lands, every earlier frame has
    #expect(await waitFor { h.sent().last?["type"] as? String == "session_end" })
    #expect(h.sent().compactMap { $0["logTranscriptText"] as? Bool } == [true, false])
}

@MainActor
@Test func req_protocol_everySendMatchesItsExample() async throws {
    let examples = try Examples.load()
    let h = Harness()
    defer { h.close() }
    h.manager.start()

    let document = "# Planning call\n\nthem: Has anyone looked at Cedar's rate limits?"
    let transcript = "them: Has anyone looked at Cedar's rate limits?\nme: I think it is 100 a second."
    // Every send the app has, each optional field the app can leave out both
    // present and absent (`card_reply.transcript` is always sent); the frame
    // types expected back, in order.
    var expected: [String] = []
    func sends(_ type: String, _ send: () -> Void) {
        expected.append(type)
        send()
    }
    sends("session_start") { h.manager.sendSessionStart("0F3B5C2A-7D1E-4F8A-9B6C-2E4D8A1F3C5B", context: "Planning call") }
    sends("session_start") { h.manager.sendSessionStart("0F3B5C2A-7D1E-4F8A-9B6C-2E4D8A1F3C5B") }
    sends("session_context") { h.manager.sendSessionContext("Planning call; Cedar is the new billing service") }
    sends("utterance") {
        h.manager.sendUtterance(
            Utterance(time: Date(), source: .them, text: "Has anyone looked at Cedar's rate limits?", latencyMs: 0))
    }
    sends("note") { h.manager.sendNote(EditorialNote(id: UUID(), time: Date(), text: "Cedar is the billing rewrite")) }
    sends("query") { h.manager.sendQuery("Cedar's rate limits") }
    sends("query") { h.manager.sendAction("answer", text: "Cedar's rate limits", triggerId: UUID().uuidString) }
    sends("config") { h.manager.sendAuto(true) }
    sends("config") { h.manager.sendLanes(3) }
    sends("config") { h.manager.sendLogTranscriptText(true) }
    sends("cancel") { h.manager.sendCancel("k7p2-7") }
    sends("card_reply") {
        #expect(
            h.manager.sendCardReply(
                cardId: "k7p2-7", kind: "answer", title: "Cedar's rate limits", base: "Cedar allows 100 a second.",
                replyText: "Is that per region?", transcript: transcript))
    }
    sends("summarise_live") { #expect(h.manager.sendSummariseLive(cardId: nil, transcript: transcript)) }
    sends("summarise_live") { #expect(h.manager.sendSummariseLive(cardId: "k7p2-9", transcript: transcript)) }
    sends("ask_document") {
        #expect(h.manager.askDocument(question: "What did we decide?", document: document) { _, _ in } != nil)
    }
    sends("research_document") {
        #expect(
            h.manager.researchDocument(action: "factcheck", text: "100 a second", document: document) { _, _ in }
                != nil)
    }
    sends("reply_document") {
        #expect(
            h.manager.replyDocument(
                kind: "answer", title: "Cedar's rate limits", base: "Cedar allows 100 a second.",
                replyText: "Is that per region?", document: document
            ) { _, _ in } != nil)
    }
    sends("summarise_document") { #expect(h.manager.summariseDocument(transcript: document) { _, _ in } != nil) }
    sends("session_end") { h.manager.sendSessionEnd() }
    #expect(await waitFor { h.sent().count == expected.count }, "sent \(h.sent().count) of \(expected.count) frames")
    let sent = h.sent()
    #expect(sent.map { $0["type"] as? String } == expected)

    // Each frame: every required field of its example, no field outside it, and
    // the same JSON kind for each field it carries.
    var coveredFields: [String: Set<String>] = [:]
    for frame in sent {
        let type = try #require(frame["type"] as? String)
        let example = try examples.appToSidecar.frame(type)
        let missing = try examples.appToSidecar.required(type).subtracting(frame.keys)
        #expect(missing.isEmpty, "\(type): required fields not sent: \(missing.sorted())")
        for (field, value) in frame {
            let expectedValue = try #require(example[field], "\(type).\(field) is sent but not in its example")
            #expect(kind(value) == kind(expectedValue), "\(type).\(field)")
            coveredFields[type, default: []].insert(field)
        }
    }
    // Each example: sent, and every field of it — the optional ones too — sent
    // by some frame, so a field the sidecar knows that the app never sends fails.
    for example in examples.appToSidecar.frames {
        let type = try #require(example["type"] as? String)
        let covered = try #require(coveredFields[type], "the app never sends \(type)")
        #expect(covered == Set(example.keys), "\(type): fields the app never sends")
    }
}

// MARK: sidecar → app

@MainActor
@Test func req_protocol_everyInboundExampleLandsOnTheApp() async throws {
    let examples = try Examples.load()
    let h = Harness()
    defer { h.close() }
    h.manager.start()
    let before = h.store.status

    // Every field of every example has a landing check below, so a field that
    // joins an example fails here until its check is written.
    let checked: [String: Set<String>] = [
        "hello": ["type", "version"],
        "card": ["type", "id", "trigger", "kind", "title", "body", "state"],
        "card_update": ["type", "id", "body", "state", "activity"],
        "document_answer": ["type", "id", "body", "state"],
    ]
    for frame in examples.sidecarToApp.frames {
        let type = try #require(frame["type"] as? String)
        #expect(Set(frame.keys) == checked[type], "\(type): fields with no landing check")
    }

    // hello: nothing to land; the app ignores it (no handshake, `version` unread).
    h.manager.handle(type: "hello", try examples.sidecarToApp.frame("hello"))
    #expect(h.store.cards.isEmpty)
    #expect(h.store.status == before)

    // card: every field onto the new Card, `trigger` anchoring it to its utterance.
    let utterance = Utterance(
        time: Date(timeIntervalSince1970: 1_760_821_260), source: .them,
        text: "Has anyone looked at Cedar's rate limits?", latencyMs: 0)
    h.store.utterances = [utterance]
    var card = try examples.sidecarToApp.frame("card")
    card["trigger"] = utterance.id.uuidString
    h.manager.handle(type: "card", card)
    let landed = try #require(h.store.cards.first)
    #expect(h.store.cards.count == 1)
    #expect(landed.id == card["id"] as? String)
    #expect(landed.kind == card["kind"] as? String)
    #expect(landed.title == card["title"] as? String)
    #expect(landed.body == card["body"] as? String)
    #expect(landed.state == card["state"] as? String)
    #expect(landed.triggerId == utterance.id.uuidString)
    #expect(landed.triggerQuote == utterance.text)
    #expect(landed.created == utterance.time)

    // card_update: body, state and activity onto that card (its example shares the id).
    let update = try examples.sidecarToApp.frame("card_update")
    #expect(update["id"] as? String == card["id"] as? String, "the card_update example updates the card example")
    h.manager.handle(type: "card_update", update)
    let updated = try #require(h.store.cards.first)
    #expect(updated.body == update["body"] as? String)
    #expect(updated.state == update["state"] as? String)
    #expect(updated.activity == update["activity"] as? String)

    // The same two frames without their optional fields: a card with no trigger
    // anchors to now, with no quote; an update with no activity clears the one
    // the full update set.
    var bareCard = card
    var fullUpdate = update
    var bareUpdate = update
    for field in examples.sidecarToApp.optional["card"] ?? [] { bareCard.removeValue(forKey: field) }
    for field in examples.sidecarToApp.optional["card_update"] ?? [] { bareUpdate.removeValue(forKey: field) }
    bareCard["id"] = "k7p2-8"
    fullUpdate["id"] = "k7p2-8"
    bareUpdate["id"] = "k7p2-8"
    h.manager.handle(type: "card", bareCard)
    h.manager.handle(type: "card_update", fullUpdate)
    #expect(h.store.cards.first { $0.id == "k7p2-8" }?.activity == update["activity"] as? String)
    h.manager.handle(type: "card_update", bareUpdate)
    let bare = try #require(h.store.cards.first { $0.id == "k7p2-8" })
    #expect(bare.triggerId == nil)
    #expect(bare.triggerQuote == nil)
    #expect(bare.created > utterance.time)
    #expect(bare.body == update["body"] as? String)
    #expect(bare.activity == nil)

    // document_answer: body and state to the request's handler, by id.
    var answers: [(body: String, state: String)] = []
    let requestId = try #require(
        h.manager.askDocument(question: "What did we decide?", document: "# Planning call") {
            answers.append((body: $0, state: $1))
        })
    var answer = try examples.sidecarToApp.frame("document_answer")
    answer["id"] = requestId
    h.manager.handle(type: "document_answer", answer)
    #expect(answers.count == 1)
    #expect(answers.first?.body == answer["body"] as? String)
    #expect(answers.first?.state == answer["state"] as? String)
}
