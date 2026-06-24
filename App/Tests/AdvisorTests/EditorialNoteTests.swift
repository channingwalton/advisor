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
