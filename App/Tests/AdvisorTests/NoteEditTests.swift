import Foundation
import Testing

@testable import Advisor

private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

private func utterance(_ secs: TimeInterval, _ text: String) -> Utterance {
    Utterance(time: t0.addingTimeInterval(secs), source: .them, text: text, latencyMs: 0)
}

private func card(_ id: String, at secs: TimeInterval, _ title: String, kind: String = "context") -> Card {
    Card(
        id: id, created: t0.addingTimeInterval(secs), kind: kind, title: title, body: "About \(title).",
        state: "done", triggerQuote: "quote \(title)")
}

/// A saved note: two paragraphs split by a card, a second card, a note and a
/// summary — the shapes the writer produces.
private let note = SessionMarkdown.inline(
    utterances: [utterance(0, "First line."), utterance(1, "Still first."), utterance(10, "Later line.")],
    cards: [
        card("a", at: 1, "Alpha"), card("b", at: 10, "Beta"),
        Card(id: "s", created: t0, kind: "summary", title: "Summary", body: "The gist.", state: "done"),
    ],
    notes: [EditorialNote(id: UUID(), time: t0.addingTimeInterval(10), text: "My note")],
    started: t0, ended: t0.addingTimeInterval(60), context: "Edit test")

private func blocks(_ markdown: String) -> [TranscriptBlock] {
    TranscriptDoc.blocks(from: SessionArchive.strippingFrontmatter(markdown))
}

private func offset(of title: String, in markdown: String) throws -> Int {
    try #require(blocks(markdown).firstIndex {
        if case .card(let m) = $0 { m.contains(title) } else { false }
    })
}

@Test func removingACardLeavesTheRestOfTheNote() throws {
    let at = try offset(of: "Alpha", in: note)
    let before = blocks(note)
    let edited = try #require(NoteEdit.removingBlock(at: at, expecting: before[at], in: note))

    var expected = before
    expected.remove(at: at)
    // The paragraphs either side were only split by the card (1s apart), so
    // they now read as one paragraph, as they would live.
    #expect(blocks(edited).contains(.paragraph("First line. Still first.")))
    #expect(!edited.contains("Alpha"))
    #expect(edited.contains("Beta"))
    #expect(edited.contains("> **NOTE**"))
    #expect(SessionArchive.frontmatter(edited) == SessionArchive.frontmatter(note))
    #expect(!edited.contains("\n\n\n"))
}

@Test func removingANoteRemovesOnlyTheNote() throws {
    let before = blocks(note)
    let at = try #require(before.firstIndex { if case .note = $0 { true } else { false } })
    let edited = try #require(NoteEdit.removingBlock(at: at, expecting: before[at], in: note))

    #expect(!edited.contains("**NOTE**"))
    #expect(blocks(edited).filter { if case .card = $0 { true } else { false } }.count == 3)
    #expect(!edited.contains("\n\n\n"))
}

@Test func removingTheSummaryRemovesItsEmptySection() throws {
    let at = try offset(of: "**SUMMARY**", in: note)
    let edited = try #require(NoteEdit.removingBlock(at: at, expecting: blocks(note)[at], in: note))

    #expect(!edited.contains("# Summary"))
    #expect(edited.contains("# Transcript"))
    #expect(blocks(edited).first == .heading("Transcript"))
}

@Test func removingTheLastFollowUpRemovesItsHeadingButNotBefore() throws {
    let one = SessionArchive.appendingFollowUp(to: note, question: "Why?", answer: "Because.", asked: t0)
    let two = SessionArchive.appendingFollowUp(to: one, question: "How?", answer: "Like so.", asked: t0)

    let why = try offset(of: "Q · Why?", in: two)
    let afterFirst = try #require(NoteEdit.removingBlock(at: why, expecting: blocks(two)[why], in: two))
    #expect(afterFirst.contains("# Follow-ups"))
    #expect(!afterFirst.contains("Why?"))
    #expect(afterFirst.contains("How?"))

    let how = try offset(of: "Q · How?", in: afterFirst)
    let afterBoth = try #require(
        NoteEdit.removingBlock(at: how, expecting: blocks(afterFirst)[how], in: afterFirst))
    #expect(!afterBoth.contains("# Follow-ups"))
    #expect(afterBoth.hasSuffix("\n"))
    #expect(!afterBoth.hasSuffix("\n\n"))
}

@Test func removingKeepsHeadingsTheUserWrote() throws {
    let custom = note + "\n# Action items\n\n> **NOTE**\n>\n> Call Bob\n"
    let at = try #require(blocks(custom).lastIndex { if case .note = $0 { true } else { false } })
    let edited = try #require(NoteEdit.removingBlock(at: at, expecting: blocks(custom)[at], in: custom))

    #expect(edited.contains("# Action items"))
    #expect(!edited.contains("Call Bob"))
}

@Test func removingTheFirstBlockLeavesNoLeadingBlank() throws {
    let md = "---\nstarted: x\n---\n\n> **CONTEXT · A**\n>\n> a\n\n- 10:00:00 Hello.\n"
    let edited = try #require(NoteEdit.removingBlock(at: 0, expecting: blocks(md)[0], in: md))
    #expect(edited == "---\nstarted: x\n---\n\n- 10:00:00 Hello.\n")
}

@Test func removingRefusesWhenTheNoteNoLongerMatches() throws {
    let at = try offset(of: "Alpha", in: note)
    #expect(NoteEdit.removingBlock(at: at, expecting: .card("**CONTEXT · Something else**"), in: note) == nil)
    #expect(NoteEdit.removingBlock(at: 999, expecting: blocks(note)[at], in: note) == nil)
}

@Test func removingRefusesTranscriptAndHeadings() {
    let all = blocks(note)
    for (i, block) in all.enumerated() {
        switch block {
        case .paragraph, .heading:
            #expect(NoteEdit.removingBlock(at: i, expecting: block, in: note) == nil)
        case .card, .note:
            continue
        }
    }
}

@Test func adjacentCardsAreRemovedIndependently() throws {
    let both = SessionMarkdown.inline(
        utterances: [utterance(0, "Line.")],
        cards: [card("a", at: 0, "Alpha"), card("b", at: 0, "Beta")],
        started: t0, ended: t0)
    let at = try offset(of: "Alpha", in: both)
    let edited = try #require(NoteEdit.removingBlock(at: at, expecting: blocks(both)[at], in: both))

    #expect(!edited.contains("Alpha"))
    let remaining = blocks(edited).compactMap { b -> String? in if case .card(let m) = b { m } else { nil } }
    #expect(remaining.count == 1)
    #expect(remaining.first?.hasPrefix("**CONTEXT · Beta**") == true)
}

// MARK: adding notes

/// Two lines 1s apart (one paragraph), then a card anchored under the second.
private let paragraphNote = SessionMarkdown.inline(
    utterances: [utterance(0, "First line."), utterance(1, "Second line."), utterance(30, "Much later.")],
    cards: [card("a", at: 1, "Alpha")],
    started: t0, ended: t0.addingTimeInterval(60))

private func paragraphOffset(_ text: String, in markdown: String) throws -> Int {
    try #require(blocks(markdown).firstIndex { $0 == .paragraph(text) })
}

@Test func addingANoteInsertsItAfterTheLineTheOffsetFallsIn() throws {
    let at = try paragraphOffset("First line. Second line.", in: paragraphNote)
    // Offset 3 is inside "First line.".
    let edited = try #require(NoteEdit.insertingNote(
        "Check this", inParagraphAt: at, expecting: blocks(paragraphNote)[at], atCharacter: 3,
        in: paragraphNote))

    let after = blocks(edited)
    #expect(after[at] == .paragraph("First line."))
    #expect(after[at + 1] == .note("Check this"))
    #expect(after[at + 2] == .paragraph("Second line."))
    #expect(SessionArchive.frontmatter(edited) == SessionArchive.frontmatter(paragraphNote))
    #expect(!edited.contains("\n\n\n"))
}

@Test func aNoteAtTheParagraphEndSitsAboveTheCardUnderIt() throws {
    let at = try paragraphOffset("First line. Second line.", in: paragraphNote)
    let end = ("First line. Second line." as NSString).length
    let edited = try #require(NoteEdit.insertingNote(
        "Line two\nmatters", inParagraphAt: at, expecting: blocks(paragraphNote)[at], atCharacter: end,
        in: paragraphNote))

    let after = blocks(edited)
    #expect(after[at] == .paragraph("First line. Second line."))
    #expect(after[at + 1] == .note("Line two\nmatters"))
    if case .card(let m) = after[at + 2] { #expect(m.hasPrefix("**CONTEXT · Alpha**")) } else {
        Issue.record("expected the card after the note")
    }
}

@Test func notesOnOneLineKeepTheirOrderAboveItsCard() throws {
    let at = try paragraphOffset("First line. Second line.", in: paragraphNote)
    let end = ("First line. Second line." as NSString).length
    let one = try #require(NoteEdit.insertingNote(
        "A", inParagraphAt: at, expecting: blocks(paragraphNote)[at], atCharacter: end, in: paragraphNote))
    let two = try #require(NoteEdit.insertingNote(
        "B", inParagraphAt: at, expecting: blocks(one)[at], atCharacter: end, in: one))

    let after = blocks(two)
    #expect(after[at + 1] == .note("A"))
    #expect(after[at + 2] == .note("B"))
    if case .card(let m) = after[at + 3] { #expect(m.hasPrefix("**CONTEXT · Alpha**")) } else {
        Issue.record("expected the card below both notes")
    }
}

@Test func addingANoteRefusesStaleOrBlankInput() throws {
    let at = try paragraphOffset("First line. Second line.", in: paragraphNote)
    let block = blocks(paragraphNote)[at]
    #expect(NoteEdit.insertingNote("x", inParagraphAt: at, expecting: .paragraph("Other."), atCharacter: 0, in: paragraphNote) == nil)
    #expect(NoteEdit.insertingNote("  ", inParagraphAt: at, expecting: block, atCharacter: 0, in: paragraphNote) == nil)
    let cardAt = try offset(of: "Alpha", in: paragraphNote)
    #expect(NoteEdit.insertingNote("x", inParagraphAt: cardAt, expecting: blocks(paragraphNote)[cardAt], atCharacter: 0, in: paragraphNote) == nil)
}

// MARK: correcting

@Test func correctingAnOccurrenceRewritesTheExpectedParagraph() throws {
    // Past the heading and the card, so the paragraph count must skip both.
    let at = try paragraphOffset("Much later.", in: paragraphNote)
    let edited = try #require(NoteEdit.correctingOccurrence(
        0, of: "later", with: "latter", inParagraphAt: at, expecting: blocks(paragraphNote)[at],
        in: paragraphNote))

    #expect(edited == paragraphNote.replacingOccurrences(of: "Much later.", with: "Much latter."))
}

/// The correction edits the lines of the paragraph it checked. An indented
/// transcript line (a hand-edited note) is its own paragraph here, as shown, and a
/// second grouping of the note that folded it into the paragraph above would
/// send the correction to the paragraph after it.
@Test func correctingAnOccurrenceEditsTheParagraphItChecked() throws {
    let note = "# Transcript\n\n- 17:00:00 alpha effect\n\n  - 17:00:30 beta effect\n\n- 17:01:00 gamma effect\n"
    let at = try paragraphOffset("beta effect", in: note)
    let edited = try #require(NoteEdit.correctingOccurrence(
        0, of: "effect", with: "affect", inParagraphAt: at, expecting: blocks(note)[at], in: note))

    #expect(edited == note.replacingOccurrences(of: "beta effect", with: "beta affect"))
}

@Test func correctingAnOccurrenceRefusesAStaleParagraphOrNoChange() throws {
    let at = try paragraphOffset("First line. Second line.", in: paragraphNote)
    let block = blocks(paragraphNote)[at]
    func correcting(_ n: Int, of original: String, at offset: Int, expecting: TranscriptBlock) -> String? {
        NoteEdit.correctingOccurrence(
            n, of: original, with: "x", inParagraphAt: offset, expecting: expecting, in: paragraphNote)
    }
    // The paragraph there isn't the one the row showed.
    #expect(correcting(0, of: "line", at: at, expecting: .paragraph("Other line.")) == nil)
    // A card, not a paragraph.
    let cardAt = try offset(of: "Alpha", in: paragraphNote)
    #expect(correcting(0, of: "Alpha", at: cardAt, expecting: blocks(paragraphNote)[cardAt]) == nil)
    // Past the blocks.
    #expect(correcting(0, of: "line", at: blocks(paragraphNote).count, expecting: block) == nil)
    // Nothing to change: no third "line", and a phrase across the two lines.
    #expect(correcting(2, of: "line", at: at, expecting: block) == nil)
    #expect(correcting(0, of: "line. Second", at: at, expecting: block) == nil)
}

@Test func noteAnchorMapsOffsetsToLines() {
    let texts = ["One", "two three", "four"]
    #expect(NoteAnchor.lineIndex(forOffset: 0, in: texts) == 0)
    #expect(NoteAnchor.lineIndex(forOffset: 3, in: texts) == 0)
    #expect(NoteAnchor.lineIndex(forOffset: 4, in: texts) == 1)
    #expect(NoteAnchor.lineIndex(forOffset: 99, in: texts) == 2)
    #expect(NoteAnchor.lineIndex(forOffset: 0, in: []) == nil)
}

// MARK: research cards

@Test func anchorIsTheParagraphsLastLine() throws {
    let at = try paragraphOffset("First line. Second line.", in: paragraphNote)
    let anchor = try #require(NoteEdit.anchor(ofParagraphAt: at, expecting: blocks(paragraphNote)[at], in: paragraphNote))
    #expect(anchor.line.hasSuffix(" Second line."))
    #expect(NoteEdit.anchor(ofParagraphAt: at, expecting: .paragraph("Other."), in: paragraphNote) == nil)
}

@Test func aResearchCardLandsBelowTheBlocksAlreadyUnderItsLine() throws {
    let at = try paragraphOffset("First line. Second line.", in: paragraphNote)
    let anchor = try #require(NoteEdit.anchor(ofParagraphAt: at, expecting: blocks(paragraphNote)[at], in: paragraphNote))
    let block = SessionMarkdown.cardBlock(
        Card(id: "r", created: t0, kind: "answer", title: "Second line.", body: "Researched.", state: "done"))
    let edited = NoteEdit.insertingBlock(block, after: anchor, in: paragraphNote)

    let after = blocks(edited)
    #expect(after[at] == .paragraph("First line. Second line."))
    if case .card(let m) = after[at + 1] { #expect(m.hasPrefix("**CONTEXT · Alpha**")) } else { Issue.record("Alpha moved") }
    if case .card(let m) = after[at + 2] { #expect(m.hasPrefix("**ANSWER · Second line.**")) } else { Issue.record("no new card") }
    #expect(after[at + 3] == .paragraph("Much later."))
    #expect(!edited.contains("\n\n\n"))
}

@Test func aResearchCardFindsItsLineAfterOtherEdits() throws {
    let at = try paragraphOffset("First line. Second line.", in: paragraphNote)
    let anchor = try #require(NoteEdit.anchor(ofParagraphAt: at, expecting: blocks(paragraphNote)[at], in: paragraphNote))
    // A note added above the anchor line while the research ran shifts it down.
    let moved = try #require(NoteEdit.insertingNote(
        "Earlier", inParagraphAt: at, expecting: blocks(paragraphNote)[at], atCharacter: 0, in: paragraphNote))
    let block = SessionMarkdown.cardBlock(
        Card(id: "r", created: t0, kind: "context", title: "X", body: "Y.", state: "done"))
    let edited = NoteEdit.insertingBlock(block, after: anchor, in: moved)

    #expect(blocks(edited).contains(.paragraph("Second line.")))
    let cards = blocks(edited).compactMap { b -> String? in if case .card(let m) = b { m } else { nil } }
    #expect(cards.map { $0.components(separatedBy: "\n")[0] } == ["**CONTEXT · Alpha**", "**CONTEXT · X**"])

}

@Test func aResearchCardFollowsItsLineThroughACorrection() throws {
    let at = try paragraphOffset("First line. Second line.", in: paragraphNote)
    let anchor = try #require(NoteEdit.anchor(ofParagraphAt: at, expecting: blocks(paragraphNote)[at], in: paragraphNote))
    let corrected = paragraphNote.replacingOccurrences(of: "Second line.", with: "Second lime.")
    let block = SessionMarkdown.cardBlock(
        Card(id: "r", created: t0, kind: "context", title: "X", body: "Y.", state: "done"))
    let edited = NoteEdit.insertingBlock(block, after: anchor, in: corrected)

    let after = blocks(edited)
    #expect(after[at] == .paragraph("First line. Second lime."))
    if case .card(let m) = after[at + 2] { #expect(m.hasPrefix("**CONTEXT · X**")) } else { Issue.record("misplaced") }
}

@Test func aResearchCardWhoseLineIsGoneEndsTheTranscript() throws {
    let followedUp = SessionArchive.appendingFollowUp(to: paragraphNote, question: "Q?", answer: "A.", asked: t0)
    let gone = NoteEdit.Anchor(index: 3, line: "- 23:59:59 Not there.")
    let block = SessionMarkdown.cardBlock(
        Card(id: "r", created: t0, kind: "context", title: "X", body: "Y.", state: "done"))
    let edited = NoteEdit.insertingBlock(block, after: gone, in: followedUp)

    let after = blocks(edited)
    let followUps = try #require(after.firstIndex(of: .heading("Follow-ups")))
    if case .card(let m) = after[followUps - 1] { #expect(m.hasPrefix("**CONTEXT · X**")) } else {
        Issue.record("expected the card at the end of the transcript")
    }
    #expect(!edited.contains("\n\n\n"))
}

@Test func inFlightCardsFollowTheirParagraphByItsLastLine() {
    let blocks: [TranscriptBlock] = [
        .paragraph("A."), .card("**CONTEXT · C**\n\nc"), .paragraph("First. Second."), .paragraph("Second."),
    ]
    #expect(NoteEdit.paragraphOffset(endingWith: "- 10:00:01 Second.", near: 2, in: blocks) == 2)
    #expect(NoteEdit.paragraphOffset(endingWith: "- 10:00:01 Second.", near: 3, in: blocks) == 3)
    // A line that no paragraph ends with (corrected meanwhile): the paragraph
    // nearest where it was, so the card stays in the transcript.
    #expect(NoteEdit.paragraphOffset(endingWith: "- 10:00:01 Gone.", near: 1, in: blocks) == 0)
    #expect(NoteEdit.paragraphOffset(endingWith: "- 10:00:01 Gone.", near: 0, in: [.heading("Summary")]) == nil)
}

@Test func savedResearchAnswersSayWhatGroundedThem() {
    let card = Card(
        id: "r", created: t0, kind: "answer", title: "Q", body: "A.", state: "done",
        footnote: SavedCard.savedGroundedNote)
    let block = SessionMarkdown.cardBlock(card)
    #expect(block.contains("> _\(SavedCard.savedGroundedNote)_"))
    let inner = block.components(separatedBy: "\n").map { $0 == ">" ? "" : String($0.dropFirst(2)) }
        .joined(separator: "\n")
    let parsed = SavedCard.card(from: inner, id: "x")
    #expect(parsed.body == "A.")
    #expect(parsed.footnote == SavedCard.savedGroundedNote)
}

// MARK: card follow-ups

@Test func aFollowUpTurnUsesTheLiveFormat() {
    #expect(SessionMarkdown.replyBody(base: "Answer.", question: "Why?", answer: "Because.")
        == "Answer.\n\n---\n\n**You:** Why?\n\nBecause.")
}

@Test func replacingACardBodyKeepsItsHeaderFooterAndNeighbours() throws {
    let before = blocks(note)
    let at = try offset(of: "Alpha", in: note)
    let id = try #require(Feed.savedIds(before)[at])
    let old = SavedCard.card(from: { if case .card(let m) = before[at] { m } else { "" } }(), id: id)
    let newBody = SessionMarkdown.replyBody(base: old.body, question: "More?", answer: "Line one.\n\n- point")

    let edited = try #require(NoteEdit.replacingCardBody(ofCard: id, body: old.body, with: newBody, in: note))
    let after = blocks(edited)
    #expect(after.count == before.count)
    guard case .card(let inner) = after[at] else { Issue.record("card gone"); return }
    let card = SavedCard.card(from: inner, id: "x")
    #expect(card.title == "Alpha")
    #expect(card.body == newBody)
    #expect(card.triggerQuote == old.triggerQuote)
    for i in before.indices where i != at { #expect(after[i] == before[i]) }
    #expect(SessionArchive.frontmatter(edited) == SessionArchive.frontmatter(note))
}

@Test func replacingACardBodyFindsTheCardAfterOtherEdits() throws {
    let at = try offset(of: "Beta", in: note)
    let id = try #require(Feed.savedIds(blocks(note))[at])
    // A card above it was deleted while the reply ran.
    let alpha = try offset(of: "Alpha", in: note)
    let moved = try #require(NoteEdit.removingBlock(at: alpha, expecting: blocks(note)[alpha], in: note))

    let edited = try #require(NoteEdit.replacingCardBody(ofCard: id, body: "About Beta.", with: "About Beta. More.", in: moved))
    #expect(edited.contains("> About Beta. More."))
    #expect(NoteEdit.replacingCardBody(ofCard: "s0-0", body: "x", with: "y", in: note) == nil)
}

@Test func withoutATranscriptHeadingAnUnplacedCardGoesBeforeTheFollowUps() {
    let md = "---\nstarted: x\n---\n\n# Summary\n\n> **SUMMARY**\n>\n> Gist.\n\n- 10:00:00 Hello.\n\n# Follow-ups\n\n> **Q · Q?**\n>\n> A.\n"
    let block = SessionMarkdown.cardBlock(
        Card(id: "r", created: t0, kind: "context", title: "X", body: "Y.", state: "done"))
    let edited = NoteEdit.insertingBlock(block, after: NoteEdit.Anchor(index: 0, line: "- 09:00:00 Gone."), in: md)

    let after = blocks(edited)
    let followUps = after.firstIndex(of: .heading("Follow-ups"))
    #expect(after.first == .heading("Summary"))
    if let followUps, case .card(let m) = after[followUps - 1] { #expect(m.hasPrefix("**CONTEXT · X**")) } else {
        Issue.record("expected the card just above Follow-ups")
    }
}

@Test func anUnplacedCardFollowsTheLastParagraphWhateverTheHeadings() {
    let block = SessionMarkdown.cardBlock(
        Card(id: "r", created: t0, kind: "context", title: "X", body: "Y.", state: "done"))
    let gone = NoteEdit.Anchor(index: 0, line: "- 09:00:00 Gone.")
    // A heading of the user's own inside the transcript, and a summary appended
    // after it (no Transcript heading), as an older note might have.
    let md = "- 10:00:00 Part one.\n\n# Part 2\n\n- 10:05:00 Part two.\n\n> **NOTE**\n>\n> Mine\n\n# Summary\n\n> **SUMMARY**\n>\n> Gist.\n"
    let edited = NoteEdit.insertingBlock(block, after: gone, in: md)

    let after = blocks(edited)
    #expect(after.map { b -> String in
        switch b {
        case .paragraph(let t): "p:\(t)"
        case .card(let m): "c:\(m.components(separatedBy: "\n")[0])"
        case .note(let t): "n:\(t)"
        case .heading(let t): "h:\(t)"
        }
    } == [
        "p:Part one.", "h:Part 2", "p:Part two.", "n:Mine", "c:**CONTEXT · X**", "h:Summary", "c:**SUMMARY**",
    ])
}

@Test func aCardsNewIdIsFoundByItsBody() throws {
    let at = try offset(of: "Beta", in: note)
    let id = try #require(Feed.savedIds(blocks(note))[at])
    let edited = try #require(NoteEdit.replacingCardBody(ofCard: id, body: "About Beta.", with: "About Beta. More.", in: note))
    let newId = NoteEdit.cardId(withBody: "About Beta. More.", in: edited)
    #expect(newId != nil && newId != id)
    #expect(newId == Feed.savedIds(blocks(edited))[at])
}
