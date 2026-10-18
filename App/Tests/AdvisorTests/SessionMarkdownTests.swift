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
    triggerQuote: String? = nil
) -> Card {
    Card(
        id: id, created: created, kind: kind, title: title, body: body, state: state,
        triggerId: nil, triggerQuote: triggerQuote)
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

@Test func inlinesEditorialNoteAsNoteBlockquote() {
    let t = Date(timeIntervalSince1970: 1_000)
    let u = Utterance(time: t, source: .them, text: "what did they call it", latencyMs: 0)
    let note = EditorialNote(
        id: UUID(), time: t.addingTimeInterval(0.5), text: "they mean project Apollo")

    let md = SessionMarkdown.inline(
        utterances: [u], cards: [], notes: [note], started: t, ended: nil)

    #expect(md.contains("> **NOTE**"))
    #expect(md.contains("> they mean project Apollo"))
    // The note sorts after the utterance it annotates (later anchor time).
    let utterIdx = md.range(of: "what did they call it")!.lowerBound
    let noteIdx = md.range(of: "they mean project Apollo")!.lowerBound
    #expect(utterIdx < noteIdx)
}

@Test func editorialNoteSortsAboveACardAtTheSameAnchorTime() {
    // A note anchored to the very line that also triggered a card must sit above
    // that card (issue #34) — the note hugs the selected text; the card sits below.
    let t = Date(timeIntervalSince1970: 1_000)
    let u = Utterance(time: t, source: .them, text: "the claim", latencyMs: 0)
    let card = makeCard(created: t, title: "Checked", body: "verdict")
    let note = EditorialNote(id: UUID(), time: t, text: "my context")

    let md = SessionMarkdown.inline(
        utterances: [u], cards: [card], notes: [note], started: t, ended: nil)

    let noteIdx = md.range(of: "**NOTE**")!.lowerBound
    let cardIdx = md.range(of: "**ANSWER · Checked**")!.lowerBound
    #expect(noteIdx < cardIdx)
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

@Test func factcheckUsesTheFactCheckLabel() {
    let t = Date(timeIntervalSince1970: 1_000)
    let card = makeCard(created: t, kind: "factcheck", title: "Claim", state: "done")

    let md = SessionMarkdown.inline(utterances: [], cards: [card], started: t, ended: nil)

    #expect(md.contains("> **FACT-CHECK · Claim**"))
}

@Test func answerCardShowsGroundingFooter() {
    let t = Date(timeIntervalSince1970: 1_000)
    let card = makeCard(created: t, kind: "answer", title: "A")

    let md = SessionMarkdown.inline(utterances: [], cards: [card], started: t, ended: nil)

    #expect(md.contains("> _Grounded in the live conversation_"))
}

@Test func contextCardShowsTriggerQuote() {
    let t = Date(timeIntervalSince1970: 1_000)
    let card = makeCard(created: t, kind: "context", title: "Ctx", triggerQuote: "the phrase")

    let md = SessionMarkdown.inline(utterances: [], cards: [card], started: t, ended: nil)

    #expect(md.contains("> _↳ the phrase_"))
}

@Test func doneSummaryCardBecomesSummarySection() {
    let t = Date(timeIntervalSince1970: 1_000)
    let summary = makeCard(
        created: t, kind: "summary", title: "Summary", body: "Gist line.\n- point one")

    let md = SessionMarkdown.inline(utterances: [], cards: [summary], started: t, ended: nil)

    #expect(md.contains("# Summary\n\n> **SUMMARY**"))
    #expect(md.contains("> Gist line."))
    // The summary leads the note, ahead of the transcript.
    let s = md.range(of: "# Summary")
    let tr = md.range(of: "# Transcript")
    #expect(s != nil && tr != nil && s!.lowerBound < tr!.lowerBound)
    // It is not also inlined as a transcript card (one summary per note).
    #expect(md.components(separatedBy: "> **SUMMARY**").count - 1 == 1)
}

@Test func inProgressSummaryWritesNoSection() {
    let t = Date(timeIntervalSince1970: 1_000)
    let streaming = makeCard(created: t, kind: "summary", body: "partial", state: "streaming")

    let md = SessionMarkdown.inline(utterances: [], cards: [streaming], started: t, ended: nil)

    #expect(!md.contains("# Summary"))
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
