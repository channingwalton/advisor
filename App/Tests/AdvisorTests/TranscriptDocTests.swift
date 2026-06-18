import Foundation
import Testing

@testable import Advisor

// Saved notes separate every entry with a blank line (`\n\n`), so the cases
// below use that real format, not single-newline input.

@Test func consecutiveLinesJoinIntoOneParagraph() {
    let body = "- 17:00:00 hello there\n\n- 17:00:01 how are you"
    #expect(TranscriptDoc.blocks(from: body) == [.paragraph("hello there how are you")])
}

@Test func gapOverTwoSecondsStartsNewParagraph() {
    let body = "- 17:00:00 first\n\n- 17:00:01 still first\n\n- 17:00:10 second"
    #expect(TranscriptDoc.blocks(from: body) == [
        .paragraph("first still first"), .paragraph("second"),
    ])
}

@Test func midnightRolloverDoesNotMergeAcrossLargeGap() {
    // 00:00:05 after 23:59:59 is a 6s gap, not a backwards 86394s jump.
    let body = "- 23:59:59 last of the day\n\n- 00:00:05 next morning"
    #expect(TranscriptDoc.blocks(from: body) == [
        .paragraph("last of the day"), .paragraph("next morning"),
    ])
}

@Test func midnightRolloverStillMergesWithinTwoSeconds() {
    let body = "- 23:59:59 keep\n\n- 00:00:01 together"
    #expect(TranscriptDoc.blocks(from: body) == [.paragraph("keep together")])
}

@Test func blockquoteBecomesCardWithInnerMarkdown() {
    let body = "- 17:00:00 a question\n\n> **ANSWER · Title**\n>\n> the body\n\n- 17:00:01 next"
    #expect(TranscriptDoc.blocks(from: body) == [
        .paragraph("a question"),
        .card("**ANSWER · Title**\n\nthe body"),
        .paragraph("next"),
    ])
}

@Test func transcriptHeadingIsKept() {
    // The view drops "Transcript" at render time; the parser surfaces all headings.
    let body = "# Transcript\n\n- 17:00:00 hi\n\n# Follow-ups\n\n> **Q · q**"
    #expect(TranscriptDoc.blocks(from: body) == [
        .heading("Transcript"),
        .paragraph("hi"),
        .heading("Follow-ups"),
        .card("**Q · q**"),
    ])
}

@Test func roundTripFromInlineMergesConsecutiveUtterances() {
    // Drive the real writer format end to end: utterances within 2s must merge
    // into one paragraph even though `inline` blank-separates them.
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let utterances = [
        Utterance(time: t0, source: .them, text: "hello there", latencyMs: 0),
        Utterance(time: t0.addingTimeInterval(1), source: .me, text: "how are you", latencyMs: 0),
    ]
    let md = SessionMarkdown.inline(utterances: utterances, cards: [], started: t0, ended: nil)
    let blocks = TranscriptDoc.blocks(from: SessionArchive.strippingFrontmatter(md))
    #expect(blocks == [.heading("Transcript"), .paragraph("hello there how are you")])
}
