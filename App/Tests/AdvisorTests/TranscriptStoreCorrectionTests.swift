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
