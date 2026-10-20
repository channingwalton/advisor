import Foundation
import Testing

@testable import Advisor

@MainActor
@Test func addNoteTrimsAppendsAndReturnsTheStoredNote() {
    let store = TranscriptStore()
    let t = Date(timeIntervalSinceReferenceDate: 100)

    let note = store.addNote("  they mean the Q1 migration  ", at: t)

    #expect(store.notes.count == 1)
    #expect(store.notes[0].text == "they mean the Q1 migration") // trimmed
    #expect(store.notes[0].time == t)
    // The returned note shares the stored note's identity, so the caller can send
    // it to the sidecar under the same id.
    #expect(note?.id == store.notes[0].id)
}

@MainActor
@Test func addNoteIgnoresBlankText() {
    let store = TranscriptStore()
    #expect(store.addNote("   \n ", at: Date()) == nil)
    #expect(store.notes.isEmpty)
}

@Test func noteAnchorPicksTheUtteranceContainingTheOffset() {
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    let t1 = Date(timeIntervalSinceReferenceDate: 1)
    let t2 = Date(timeIntervalSinceReferenceDate: 2)
    // Paragraph text the NSTextView shows = "alpha beta gamma" (joined by spaces):
    // alpha=0..5, space@5, beta=6..10, space@10, gamma=11..16.
    let parts = [("alpha", t0), ("beta", t1), ("gamma", t2)]
    #expect(NoteAnchor.time(forOffset: 0, in: parts) == t0) // start of alpha
    #expect(NoteAnchor.time(forOffset: 5, in: parts) == t0) // trailing space stays with alpha
    #expect(NoteAnchor.time(forOffset: 7, in: parts) == t1) // inside beta
    #expect(NoteAnchor.time(forOffset: 13, in: parts) == t2) // inside gamma
    #expect(NoteAnchor.time(forOffset: 999, in: parts) == t2) // past the end → last line
}

@Test func noteAnchorIsNilForAnEmptyParagraph() {
    #expect(NoteAnchor.time(forOffset: 0, in: []) == nil)
}

@MainActor
@Test func dismissNoteRemovesByID() {
    let store = TranscriptStore()
    let a = store.addNote("first", at: Date(timeIntervalSinceReferenceDate: 0))!
    let b = store.addNote("second", at: Date(timeIntervalSinceReferenceDate: 1))!

    store.dismissNote(a.id)

    #expect(store.notes.map(\.id) == [b.id])
}

/// A live paragraph's lines, as a note placed in it maps its offset over them:
/// in order, without any removed since (echo cleanup) — none once all have gone.
@MainActor
@Test func linesListsTheUtterancesStillThereInOrder() {
    let store = TranscriptStore()
    let a = Utterance(time: Date(timeIntervalSinceReferenceDate: 0), source: .them, text: "alpha", latencyMs: 0)
    let b = Utterance(time: Date(timeIntervalSinceReferenceDate: 1), source: .me, text: "beta", latencyMs: 0)
    store.utterances = [a, b]

    #expect(store.lines([b.id, a.id]).map(\.text) == ["beta", "alpha"])
    #expect(store.lines([a.id, UUID()]).map(\.text) == ["alpha"])
    #expect(store.lines([UUID()]).isEmpty)
}

/// Listen keeps the notes typed and the questions asked before it (issue #104)
/// — all an idle window holds, since closing it clears the store — and hands the
/// notes back so they can be sent to the agents after `session_start` clears
/// the sidecar's transcript. Lines start afresh, under a new generation.
@MainActor
@Test func beginSessionKeepsNotesAndAsksFromBeforeListen() {
    let store = TranscriptStore()
    let note = store.addNote("Bob is the CFO", at: Date(timeIntervalSinceReferenceDate: 0))!
    let asked = Card(id: "c", created: Date(), kind: "query", title: "Q", body: "A", state: "streaming")
    store.cards = [asked]
    store.utterances = [Utterance(time: Date(), source: .them, text: "Hello", latencyMs: 0)]
    let generation = store.sessionGeneration

    let replay = store.beginSession()

    #expect(replay == [note])
    #expect(store.notes == [note])
    #expect(store.cards.map(\.id) == [asked.id])
    #expect(store.utterances.isEmpty)
    #expect(store.sessionGeneration == generation + 1)
}

private func paragraph(_ lines: [String]) -> FeedParagraph {
    FeedParagraph(
        id: "p", lines: lines.enumerated().map { FeedLine(id: "\($0.offset)", text: $0.element) }, time: nil)
}

/// The Note popover quotes the line a right-clicked note goes under — the one
/// the click or selection end falls in, as the note is placed.
@Test func notePlacementQuotesTheLineTheOffsetFallsIn() {
    let p = paragraph(["alpha", "beta", "gamma"])
    #expect(NotePlacement(offset: 0, paragraph: p).line == "alpha")
    #expect(NotePlacement(offset: 7, paragraph: p).line == "beta")
    #expect(NotePlacement(offset: 999, paragraph: p).line == "gamma")
}

/// Submitting a draft hands over its trimmed text and placement, and starts
/// afresh only once the note is added: one that couldn't be saved stays to try
/// again, and a blank draft adds nothing.
@Test func submittingANoteDraftClearsItOnlyOnceAdded() {
    let placement = NotePlacement(offset: 7, paragraph: paragraph(["alpha", "beta"]))
    var draft = NoteDraft(text: "  \n ", placement: placement)
    var added: [(String, NotePlacement?)] = []
    #expect(!draft.submit { added.append(($0, $1)); return true })
    #expect(added.isEmpty)
    #expect(draft.placement == placement)

    draft.text = "  they mean Q1  "
    #expect(!draft.submit { _, _ in false })
    #expect(draft == NoteDraft(text: "  they mean Q1  ", placement: placement))

    #expect(draft.submit { added.append(($0, $1)); return true })
    #expect(added.map(\.0) == ["they mean Q1"])
    #expect(added.map(\.1) == [placement])
    #expect(draft == NoteDraft())
}

/// The toolbar's draft dot and the submit button agree: whitespace isn't a draft.
@Test func aNoteDraftOfWhitespaceIsBlank() {
    #expect(NoteDraft(text: " \n ").isBlank)
    #expect(!NoteDraft(text: " x ").isBlank)
}
