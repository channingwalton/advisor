import Testing
@testable import Advisor

private final class HandlerCapture {}

@MainActor
@Test func sidecarFailureFailsAndClearsEveryDocumentRequest() {
    let handlers = DocumentRequestHandlers()
    var updates: [(String, String, String)] = []

    handlers.register("question") { body, state in
        updates.append(("question", body, state))
    }
    handlers.register("summary") { body, state in
        updates.append(("summary", body, state))
    }

    handlers.failAll(reason: "sidecar crashed")

    #expect(handlers.count == 0)
    #expect(updates.count == 2)
    #expect(updates.allSatisfy { $0.1 == "sidecar crashed" && $0.2 == "failed" })

    handlers.receive(id: "question", body: "late", state: "done")
    #expect(updates.count == 2)
}

@MainActor
@Test func terminalDocumentAnswerReleasesItsHandler() {
    let handlers = DocumentRequestHandlers()
    var updates: [(String, String)] = []

    handlers.register("request") { updates.append(($0, $1)) }
    handlers.receive(id: "request", body: "answer", state: "done")
    handlers.receive(id: "request", body: "late", state: "streaming")

    #expect(handlers.count == 0)
    #expect(updates.count == 1)
    #expect(updates[0].0 == "answer")
    #expect(updates[0].1 == "done")
}

@MainActor
@Test func sidecarFailureReleasesCapturedViewState() {
    let handlers = DocumentRequestHandlers()
    var capture: HandlerCapture? = HandlerCapture()
    weak let weakCapture = capture

    handlers.register("request") { [capture] _, _ in _ = capture }
    capture = nil
    #expect(weakCapture != nil)

    handlers.failAll(reason: "sidecar stopped")

    #expect(weakCapture == nil)
}
