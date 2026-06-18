import Testing
import Foundation

@testable import Advisor

private func makeCard(
    id: String = "c1",
    created: Date,
    kind: String = "answer",
    title: String = "Title",
    body: String = "Body text.",
    state: String = "done",
    triggerQuote: String? = nil,
    verdict: Verdict? = nil,
    sources: [Citation] = []
) -> Card {
    Card(
        id: id, created: created, kind: kind, title: title, body: body, state: state,
        triggerId: nil, triggerQuote: triggerQuote, sources: sources, verdict: verdict)
}

@Test func inlinesCardsAsBlockquotesWithoutFootnotes() {
    let t = Date(timeIntervalSince1970: 1_000)
    let u = Utterance(time: t, source: .them, text: "what's the weather forecast", latencyMs: 0)
    let card = makeCard(created: t, title: "Weather this week", body: "Sunny, 72°F.")

    let md = SessionMarkdown.inline(utterances: [u], cards: [card], started: t, ended: nil)

    #expect(md.contains("> **ANSWER · Weather this week**"))
    #expect(md.contains("> Sunny, 72°F."))
    // Inlined: no footnote refs/definitions and no footnote "Cards" section.
    #expect(!md.contains("[^"))
    #expect(!md.contains("# Cards"))
}

@Test func excludesInFlightCards() {
    let t = Date(timeIntervalSince1970: 1_000)
    let pending = makeCard(created: t, title: "Pending", state: "pending")
    let streaming = makeCard(id: "c2", created: t, title: "Streaming", state: "streaming")

    let md = SessionMarkdown.inline(utterances: [], cards: [pending, streaming], started: t, ended: nil)

    #expect(!md.contains("Pending"))
    #expect(!md.contains("Streaming"))
}

@Test func cardSortsAfterItsTriggerLine() {
    let t = Date(timeIntervalSince1970: 1_000)
    let u = Utterance(time: t, source: .them, text: "trigger line", latencyMs: 0)
    // Card created at the same instant as the utterance (anchored to it).
    let card = makeCard(created: t, title: "Answer card")

    let md = SessionMarkdown.inline(utterances: [u], cards: [card], started: t, ended: nil)

    let lineIdx = md.range(of: "trigger line")
    let cardIdx = md.range(of: "Answer card")
    #expect(lineIdx != nil && cardIdx != nil)
    #expect(lineIdx!.lowerBound < cardIdx!.lowerBound)
}

@Test func factcheckUsesVerdictLabel() {
    let t = Date(timeIntervalSince1970: 1_000)
    let card = makeCard(
        created: t, kind: "factcheck", title: "Claim", state: "done", verdict: .misleading)

    let md = SessionMarkdown.inline(utterances: [], cards: [card], started: t, ended: nil)

    #expect(md.contains("> **MISLEADING · Claim**"))
}

@Test func answerCardShowsGroundingFooter() {
    let t = Date(timeIntervalSince1970: 1_000)
    let card = makeCard(created: t, kind: "answer", title: "A")

    let md = SessionMarkdown.inline(utterances: [], cards: [card], started: t, ended: nil)

    #expect(md.contains("> _Grounded in the live conversation_"))
}

@Test func contextCardShowsTriggerQuoteAndSources() {
    let t = Date(timeIntervalSince1970: 1_000)
    let card = makeCard(
        created: t, kind: "context", title: "Ctx", triggerQuote: "the phrase",
        sources: [Citation(label: "BBC", url: "https://bbc.co.uk")])

    let md = SessionMarkdown.inline(utterances: [], cards: [card], started: t, ended: nil)

    #expect(md.contains("↳ the phrase"))
    #expect(md.contains("[BBC](https://bbc.co.uk)"))
}

@Test func frontmatterCarriesName() {
    let md = SessionMarkdown.inline(
        utterances: [], cards: [], started: Date(timeIntervalSince1970: 0), ended: nil,
        context: "ctx", name: "Board review\nextra")
    // The optional name collapses to one frontmatter scalar, like context.
    #expect(md.contains("name: Board review extra\n"))
}

@Test func omitsAbsentName() {
    let md = SessionMarkdown.inline(
        utterances: [], cards: [], started: Date(timeIntervalSince1970: 0), ended: nil)
    #expect(!md.contains("name:"))
}

@Test func frontmatterCarriesStartedAndEnded() {
    let started = Date(timeIntervalSince1970: 1_000)
    let ended = Date(timeIntervalSince1970: 2_000)

    let md = SessionMarkdown.inline(utterances: [], cards: [], started: started, ended: ended)

    #expect(md.hasPrefix("---\n"))
    #expect(md.contains("started: "))
    #expect(md.contains("ended: "))
}
