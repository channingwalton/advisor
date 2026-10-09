import Testing
import Foundation

@testable import Advisor

// While a card researches it shows what the agent is doing (the sidecar's
// `activity`). Each update replaces the line, and it never outlives the
// research: a finished, failed or cancelled card shows none.

private func researching() -> Card {
    var card = Card(id: "c1", created: Date(timeIntervalSince1970: 1_000), kind: "answer", title: "Cedar",
                    body: "…", state: "pending")
    card.apply(body: "…", state: "pending", activity: "Searching the web for “Cedar”")
    return card
}

@Test func req_card_activity() {
    var card = researching()
    #expect(card.activity == "Searching the web for “Cedar”")

    card.apply(body: "Cedar is", state: "streaming", activity: "Reading example.com")
    #expect(card.activity == "Reading example.com")

    // An update without one means the agent is writing again.
    card.apply(body: "Cedar is our", state: "streaming")
    #expect(card.activity == nil)
}

@Test func activityEndsWithTheResearch() {
    let ends: [(inout Card) -> Void] = [
        { $0.apply(body: "Cedar is a migration.", state: "done", activity: "Thinking…") },
        { $0.apply(body: nil, state: "failed") },  // a sidecar crash
        { $0.cancel() },
    ]
    for end in ends {
        var card = researching()
        end(&card)
        #expect(card.activity == nil)
    }
}
