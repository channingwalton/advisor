import Foundation
import Testing

@testable import Advisor

private func utterance(_ text: String, at seconds: TimeInterval = 0) -> Utterance {
    Utterance(
        time: Date(timeIntervalSinceReferenceDate: seconds), source: .them,
        text: text, latencyMs: 0)
}

@MainActor
@Test func correctOccurrenceEditsTheRightUtteranceInPlace() {
    let store = TranscriptStore()
    let a = utterance("hello widgets are great")
    let b = utterance("widgets again", at: 1)
    let c = utterance("unrelated", at: 1)
    store.utterances = [a, b, c]

    // Paragraph is [a, b]; "widgets" occurs at index 0 (a) and 1 (b).
    store.correctOccurrence(
        1, of: "widgets", with: "gadgets", inParagraph: [a.id, b.id])

    #expect(store.utterances[0].text == "hello widgets are great") // untouched
    #expect(store.utterances[1].text == "gadgets again") // corrected
    #expect(store.utterances[2].text == "unrelated") // outside the paragraph
    // Identity preserved (correction is in place, not a replacement).
    #expect(store.utterances[1].id == b.id)
}

@MainActor
@Test func correctOccurrenceOutOfRangeLeavesEverythingAlone() {
    let store = TranscriptStore()
    let a = utterance("one widget")
    store.utterances = [a]
    store.correctOccurrence(5, of: "widget", with: "gadget", inParagraph: [a.id])
    #expect(store.utterances[0].text == "one widget")
}

@MainActor
@Test func correctAllReplacesEveryOccurrenceAcrossTheSession() {
    let store = TranscriptStore()
    store.utterances = [
        utterance("widgets and widgets"),
        utterance("more widgets", at: 1),
        utterance("none here", at: 2),
    ]
    store.correctAll(of: "widgets", with: "gadgets")
    #expect(store.utterances[0].text == "gadgets and gadgets")
    #expect(store.utterances[1].text == "more gadgets")
    #expect(store.utterances[2].text == "none here")
}

@MainActor
@Test func correctAllEmptyOriginalIsANoOp() {
    let store = TranscriptStore()
    store.utterances = [utterance("keep me")]
    store.correctAll(of: "", with: "x")
    #expect(store.utterances[0].text == "keep me")
}

/// The menu counts the selection's occurrence over the paragraph as shown — its
/// utterances joined by single spaces — so a match across a join counts there,
/// and the store must count the same way (issue #92).
@MainActor
@Test func correctOccurrenceCountsOverTheParagraphAsShown() {
    let store = TranscriptStore()
    let a = utterance("this is")
    let b = utterance("a cat, this is a dog, this is a bird", at: 1)
    store.utterances = [a, b]

    // Over "this is a cat, this is a dog, this is a bird": index 1 is "is a dog".
    store.correctOccurrence(1, of: "is a", with: "was a", inParagraph: [a.id, b.id])
    #expect(store.utterances[0].text == "this is")
    #expect(store.utterances[1].text == "a cat, this was a dog, this is a bird")

    // Index 0 straddles the join: refused, nothing else is rewritten.
    store.correctOccurrence(0, of: "is a", with: "was a", inParagraph: [a.id, b.id])
    #expect(store.utterances[0].text == "this is")
    #expect(store.utterances[1].text == "a cat, this was a dog, this is a bird")
}

/// The count was taken over the paragraph as shown. If one of its utterances has
/// gone since (echo cleanup while the prompt was open), counting over what is
/// left would land on a different match, so the correction is refused.
@MainActor
@Test func correctOccurrenceRefusesAParagraphMissingAnUtterance() {
    let store = TranscriptStore()
    let a = utterance("this is")
    let b = utterance("a cat, this is a dog, this is a bird", at: 1)
    store.utterances = [b]  // `a` was removed after the menu counted [a, b]

    store.correctOccurrence(1, of: "is a", with: "was a", inParagraph: [a.id, b.id])
    #expect(store.utterances[0].text == "a cat, this is a dog, this is a bird")
}
