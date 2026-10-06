import Testing
import Foundation

@testable import Advisor

// A card that has completed once never falls back below that answer — not in
// the saved note while a follow-up or re-summarise is in flight (a quit or a
// window close writes the store as it stands), and not after one is cancelled
// or a re-summarise fails (code review 2026-10-06).

private let t0 = Date(timeIntervalSince1970: 1_000)

private func doneCard(kind: String = "answer", body: String) -> Card {
    var card = Card(id: "c1", created: t0, kind: kind, title: "Cedar", body: "…", state: "pending")
    card.apply(body: body, state: "done")
    return card
}

private func note(_ cards: [Card]) -> String {
    let u = Utterance(time: t0, source: .them, text: "what is Cedar", latencyMs: 0)
    return SessionMarkdown.inline(utterances: [u], cards: cards, started: t0, ended: nil)
}

private let followUp = SessionMarkdown.replyBody(base: "Our migration.", question: "Who owns it?", answer: "…")

/// A follow-up in flight keeps the answer in the note.
@Test func req_card_settled_note() {
    var card = doneCard(body: "Our migration.")
    card.apply(body: followUp, state: "streaming")

    let md = note([card])
    #expect(md.contains("> Our migration."))
    #expect(!md.contains("Who owns it?"))
}

@Test func cancellingAFollowUpRestoresTheAnswer() {
    for cancel in [{ (c: inout Card) in c.cancel() }, { (c: inout Card) in c.apply(body: nil, state: "cancelled") }] {
        var card = doneCard(body: "Our migration.")
        card.replying = true
        card.apply(body: followUp, state: "streaming")
        cancel(&card)

        #expect(card.state == "done")
        #expect(card.body == "Our migration.")
        #expect(!card.replying)
        #expect(note([card]).contains("> Our migration."))
    }
}

@Test func aFailedFollowUpKeepsItsThread() {
    // The sidecar's failed reply body already carries the original answer.
    var card = doneCard(body: "Our migration.")
    let failed = SessionMarkdown.replyBody(base: "Our migration.", question: "Who owns it?", answer: "failed: timed out")
    card.apply(body: followUp, state: "streaming")
    card.apply(body: failed, state: "failed")

    #expect(card.state == "failed")
    #expect(card.body == failed)
    #expect(note([card]).contains("Our migration."))
}

@Test func reSummarisingKeepsThePreviousSummaryInTheNote() {
    var card = doneCard(kind: "summary", body: "We agreed on Cedar.")
    card.apply(body: "…", state: "pending")

    #expect(SessionMarkdown.summaryText(in: [card]) == "We agreed on Cedar.")
    #expect(note([card]).contains("> We agreed on Cedar."))
}

/// A failed re-summarise keeps the previous summary and says so.
@Test func req_card_settled_summary() {
    var card = doneCard(kind: "summary", body: "We agreed on Cedar.")
    card.apply(body: "…", state: "pending")
    card.apply(body: "failed: timed out", state: "failed")

    #expect(card.body.hasPrefix("We agreed on Cedar."))
    #expect(card.body.contains("Couldn't update the summary"))
    #expect(card.body.contains("timed out"))
    #expect(card.state == "failed") // not researching: Summarise can run again
    // The note keeps the summary itself, without the failure line.
    #expect(SessionMarkdown.summaryText(in: [card]) == "We agreed on Cedar.")
    #expect(!note([card]).contains("Couldn't update"))
}

@Test func aCardThatNeverCompletedStaysOutOfTheNote() {
    var card = Card(id: "c1", created: t0, kind: "answer", title: "Cedar", body: "…", state: "pending")
    card.apply(body: "partial", state: "streaming")
    #expect(!note([card]).contains("partial"))
    card.cancel()
    #expect(card.state == "cancelled")
    #expect(!note([card]).contains("partial"))
}

@Test func aNewAnswerBecomesTheSettledOne() {
    var card = doneCard(body: "Our migration.")
    let answered = SessionMarkdown.replyBody(base: "Our migration.", question: "Who owns it?", answer: "Priya.")
    card.replying = true
    card.apply(body: answered, state: "done")
    #expect(!card.replying)
    card.apply(body: "…", state: "streaming")
    #expect(note([card]).contains("Priya."))
}

@Test func aReSummariseCutOffByASidecarCrashKeepsThePreviousSummary() {
    // A crash fails in-flight cards without a body of its own (issue #49).
    var card = doneCard(kind: "summary", body: "We agreed on Cedar.")
    card.apply(body: "…", state: "pending")
    card.apply(body: nil, state: "failed")

    #expect(card.body == "We agreed on Cedar.\n\n*Couldn't update the summary.*")
    #expect(SessionMarkdown.summaryText(in: [card]) == "We agreed on Cedar.")
}

@Test func aFailedReSummariseNamesTheSidecarsReason() {
    for (failure, reason) in [("failed: timed out", "timed out"), ("error: boom", "error: boom"),
                              ("no answer produced", "no answer produced")] {
        var card = doneCard(kind: "summary", body: "We agreed on Cedar.")
        card.apply(body: "…", state: "pending")
        card.apply(body: failure, state: "failed")
        #expect(card.body == "We agreed on Cedar.\n\n*Couldn't update the summary: \(reason)*")
    }
}

@MainActor
@Test func aCardMidFollowUpCountsAsExportableContent() {
    // An Ask-box card can be a session's only content.
    let store = TranscriptStore()
    var card = doneCard(kind: "query", body: "Our migration.")
    card.apply(body: followUp, state: "streaming")
    store.cards = [card]
    let writer = SessionWriter(store: store, resolveDirectory: { FileManager.default.temporaryDirectory })
    #expect(writer.hasExportContent)
}

@Test func aFailedReSummarisesReasonCannotBreakTheItalicLine() {
    var card = doneCard(kind: "summary", body: "We agreed on Cedar.")
    card.apply(body: "…", state: "pending")
    card.apply(body: "error: bad *glob*\n    at stack frame", state: "failed")
    #expect(card.body == "We agreed on Cedar.\n\n*Couldn't update the summary: error: bad glob*")
}

@Test func stopAndCloseThenTheSidecarsAcknowledgementKeepsTheAnswer() {
    // terminateAgents cancels locally; the sidecar then confirms with this frame.
    var card = doneCard(body: "Our migration.")
    card.apply(body: followUp, state: "streaming")
    card.cancel()
    card.apply(body: "cancelled", state: "cancelled")
    #expect(card.state == "done")
    #expect(card.body == "Our migration.")
}

@Test func aFollowUpCutOffByASidecarCrashKeepsTheAnswer() {
    // A crash fails in-flight cards with no body of its own (issue #49).
    var card = doneCard(body: "Our migration.")
    card.replying = true
    card.apply(body: followUp, state: "streaming")
    card.apply(body: nil, state: "failed")
    #expect(card.state == "done") // the reply box comes back
    #expect(card.body == "Our migration.")
    #expect(!card.replying)
    #expect(!note([card]).contains("Who owns it?"))
}

@Test func aFailedReSummarisesReasonIsPlainTextOrNothing() {
    for (failure, expected) in [("failed: ", "."), ("error: **", ": error:"),
                                ("error: ENOENT /tmp/_x_/`f` [1]", ": error: ENOENT /tmp/x/f 1")] {
        var card = doneCard(kind: "summary", body: "We agreed on Cedar.")
        card.apply(body: "…", state: "pending")
        card.apply(body: failure, state: "failed")
        #expect(card.body == "We agreed on Cedar.\n\n*Couldn't update the summary\(expected)*", "\(failure)")
    }
}
