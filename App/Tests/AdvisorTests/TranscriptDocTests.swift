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

@Test func noteBlockquoteBecomesNoteBlock() {
    // An editorial note is a `**NOTE**`-headed blockquote — parsed as `.note`,
    // not a `.card`, so it renders in its own (green) chrome (issue #34).
    let body = "- 17:00:00 a line\n\n> **NOTE**\n>\n> my own context\n\n- 17:00:01 next"
    #expect(TranscriptDoc.blocks(from: body) == [
        .paragraph("a line"),
        .note("my own context"),
        .paragraph("next"),
    ])
}

@Test func multilineNoteKeepsItsBody() {
    let body = "> **NOTE**\n>\n> line one\n> line two"
    #expect(TranscriptDoc.blocks(from: body) == [.note("line one\nline two")])
}

@Test func roundTripFromInlinePreservesNotes() {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let utterances = [Utterance(time: t0, source: .them, text: "hello", latencyMs: 0)]
    let notes = [
        EditorialNote(id: UUID(), time: t0.addingTimeInterval(0.5), text: "they mean project Apollo")
    ]
    let md = SessionMarkdown.inline(
        utterances: utterances, cards: [], notes: notes, started: t0, ended: nil)
    let blocks = TranscriptDoc.blocks(from: SessionArchive.strippingFrontmatter(md))
    #expect(blocks == [
        .heading("Transcript"), .paragraph("hello"), .note("they mean project Apollo"),
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

@Test func paragraphsCarryTheTimeOfTheirFirstLine() {
    let body = """
    # Transcript

    - 17:00:00 One.

    - 17:00:01 Two.

    - 17:05:09 Three.

    > **CONTEXT · x**
    """
    let timed = TranscriptDoc.timedBlocks(from: body)
    #expect(timed.map(\.block) == TranscriptDoc.blocks(from: body))
    #expect(timed.map(\.time) == [nil, "17:00", "17:05", nil])
}

@Test func unstampedParagraphHasNoTime() {
    #expect(TranscriptDoc.timedBlocks(from: "Loose prose line.").map(\.time) == [nil])
}

// MARK: replacingMemberText (issue #93)

@Test func replacingMemberTextKeepsEverythingButTheText() {
    // Indentation, bullet, stamp and trailing whitespace stay; only the text
    // `memberText` reads is replaced — the stamp is never reachable.
    #expect(TranscriptDoc.replacingMemberText(of: "  - 17:00:30 beta 17  ", with: "beta 18") == "  - 17:00:30 beta 18  ")
    #expect(TranscriptDoc.replacingMemberText(of: "- 17:00:00 00", with: "XX") == "- 17:00:00 XX")
    #expect(TranscriptDoc.replacingMemberText(of: "- stampless", with: "text") == "- text")
    #expect(TranscriptDoc.replacingMemberText(of: "  prose", with: "text") == "  text")
    // The replacement is read back the same way.
    #expect(TranscriptDoc.memberText(TranscriptDoc.replacingMemberText(of: "  - 17:00:30 beta", with: "gamma")!) == "gamma")
}

@Test func replacingMemberTextIsNilWithoutText() {
    #expect(TranscriptDoc.replacingMemberText(of: "- 17:00:00", with: "x") == nil)
    #expect(TranscriptDoc.replacingMemberText(of: "   ", with: "x") == nil)
}
