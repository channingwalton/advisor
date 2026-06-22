import Foundation
import Testing

@testable import Advisor

// MARK: occurrenceIndex

@Test func occurrenceIndexEmptyOriginalIsZero() {
    #expect(TranscriptCorrection.occurrenceIndex(of: "", before: 5, in: "hello") == 0)
}

@Test func occurrenceIndexBeforeFirstOccurrenceIsZero() {
    #expect(TranscriptCorrection.occurrenceIndex(of: "cat", before: 0, in: "cat cat cat") == 0)
}

@Test func occurrenceIndexCountsOccurrencesStrictlyBeforeLocation() {
    // "cat" at offsets 0, 4, 8. A selection starting at 8 has two before it.
    #expect(TranscriptCorrection.occurrenceIndex(of: "cat", before: 8, in: "cat cat cat") == 2)
    // A selection starting at 4 has one before it.
    #expect(TranscriptCorrection.occurrenceIndex(of: "cat", before: 4, in: "cat cat cat") == 1)
}

@Test func occurrenceIndexIsNonOverlapping() {
    // "aa" in "aaaa": non-overlapping starts at 0 and 2.
    #expect(TranscriptCorrection.occurrenceIndex(of: "aa", before: 2, in: "aaaa") == 1)
    // Both occurrences (start 0 and start 2) begin before offset 3.
    #expect(TranscriptCorrection.occurrenceIndex(of: "aa", before: 3, in: "aaaa") == 2)
}

// MARK: replacingOccurrence over [String]

@Test func replaceNthNilForEmptyOriginalOrBadIndex() {
    #expect(TranscriptCorrection.replacingOccurrence(0, of: "", with: "x", in: ["cat"]) == nil)
    #expect(TranscriptCorrection.replacingOccurrence(-1, of: "cat", with: "x", in: ["cat"]) == nil)
    #expect(TranscriptCorrection.replacingOccurrence(3, of: "cat", with: "x", in: ["cat cat"]) == nil)
}

@Test func replaceNthHitsTheRightOccurrenceWithinOneString() {
    #expect(
        TranscriptCorrection.replacingOccurrence(1, of: "cat", with: "dog", in: ["cat cat cat"])
            == ["cat dog cat"])
}

@Test func replaceNthCountsAcrossTheSequenceInOrder() {
    // Occurrences: index 0 in "a cat", index 1 in "cat", index 2 in "cat here".
    let texts = ["a cat", "cat", "cat here"]
    #expect(
        TranscriptCorrection.replacingOccurrence(1, of: "cat", with: "dog", in: texts)
            == ["a cat", "dog", "cat here"])
    #expect(
        TranscriptCorrection.replacingOccurrence(2, of: "cat", with: "dog", in: texts)
            == ["a cat", "cat", "dog here"])
}

// MARK: replacingAll over [String]

@Test func replaceAllAcrossStrings() {
    #expect(
        TranscriptCorrection.replacingAll(of: "cat", with: "dog", in: ["cat cat", "the cat"])
            == ["dog dog", "the dog"])
}

@Test func replaceAllEmptyOriginalUnchanged() {
    #expect(TranscriptCorrection.replacingAll(of: "", with: "x", in: ["cat"]) == ["cat"])
}

// MARK: markdown fixtures

/// A saved note in the exact shape `SessionMarkdown.inline` writes: frontmatter,
/// `# Transcript`, blank-line-separated entries, an inline card blockquote.
private let sampleNote = """
---
started: 2026-06-22T17:00:00Z
context: meeting about widgets
tags: work
---

# Transcript

- 17:00:00 hello widgets are great

- 17:00:01 widgets again

> **ANSWER · Title**
>
> widgets in card body

- 17:00:10 second paragraph widgets
"""

// MARK: replacingAllInTranscript

@Test func replaceAllInTranscriptTouchesOnlyTranscriptText() {
    let out = TranscriptCorrection.replacingAllInTranscript(
        of: "widgets", with: "gadgets", inMarkdown: sampleNote)
    // Frontmatter context line untouched.
    #expect(out.contains("context: meeting about widgets"))
    // Card body untouched.
    #expect(out.contains("> widgets in card body"))
    // Every transcript utterance line corrected.
    #expect(out.contains("- 17:00:00 hello gadgets are great"))
    #expect(out.contains("- 17:00:01 gadgets again"))
    #expect(out.contains("- 17:00:10 second paragraph gadgets"))
}

@Test func replaceAllInTranscriptNeverAltersATimestamp() {
    let note = "---\nstarted: x\n---\n\n# Transcript\n\n- 17:00:00 score is 00 now"
    let out = TranscriptCorrection.replacingAllInTranscript(
        of: "00", with: "XX", inMarkdown: note)
    #expect(out.contains("- 17:00:00 score is XX now"))
}

@Test func replaceAllInTranscriptEmptyOriginalUnchanged() {
    #expect(
        TranscriptCorrection.replacingAllInTranscript(of: "", with: "x", inMarkdown: sampleNote)
            == sampleNote)
}

// MARK: replacingOccurrence in paragraph

@Test func replaceOccurrenceInParagraphHitsTheRightLine() {
    // Paragraph 0 is the first two lines; "widgets" occurs at 0 (line 1) and 1 (line 2).
    let out = TranscriptCorrection.replacingOccurrence(
        1, of: "widgets", with: "gadgets", inParagraph: 0, ofMarkdown: sampleNote)
    #expect(out.contains("- 17:00:00 hello widgets are great")) // untouched
    #expect(out.contains("- 17:00:01 gadgets again")) // corrected
    #expect(out.contains("> widgets in card body")) // card untouched
    #expect(out.contains("- 17:00:10 second paragraph widgets")) // other paragraph untouched
}

@Test func replaceOccurrenceParagraphIndexSkipsCards() {
    // The card between them must not shift the second paragraph's index off by one.
    let out = TranscriptCorrection.replacingOccurrence(
        0, of: "widgets", with: "gadgets", inParagraph: 1, ofMarkdown: sampleNote)
    #expect(out.contains("- 17:00:10 second paragraph gadgets"))
    #expect(out.contains("- 17:00:00 hello widgets are great")) // paragraph 0 untouched
}

@Test func replaceOccurrenceOutOfRangeReturnsUnchanged() {
    #expect(
        TranscriptCorrection.replacingOccurrence(
            0, of: "widgets", with: "gadgets", inParagraph: 9, ofMarkdown: sampleNote) == sampleNote)
    #expect(
        TranscriptCorrection.replacingOccurrence(
            9, of: "widgets", with: "gadgets", inParagraph: 0, ofMarkdown: sampleNote) == sampleNote)
}

@Test func replaceOccurrenceLeavesFrontmatterIntact() {
    let out = TranscriptCorrection.replacingOccurrence(
        0, of: "widgets", with: "gadgets", inParagraph: 0, ofMarkdown: sampleNote)
    #expect(out.hasPrefix("---\nstarted: 2026-06-22T17:00:00Z\ncontext: meeting about widgets\ntags: work\n---\n"))
}

/// An empty-text `- HH:MM:SS` line (only producible by a hand-edit — `Recorder`
/// guards `!text.isEmpty`) must not create a phantom paragraph, or the saved
/// "this occurrence" path would target the wrong line. Paragraph indexing must
/// stay in lock-step with `TranscriptDoc`.
private let noteWithEmptyLine = """
---
started: x
---

# Transcript

- 17:00:00 alpha widget

> **ANSWER · a**
>
> a body

- 17:00:30

> **ANSWER · b**
>
> b body

- 17:01:00 beta widget

- 17:30:00 charlie widget
"""

@Test func emptyTextLineDoesNotCreateAPhantomParagraph() {
    // TranscriptDoc sees three paragraphs: alpha(0), beta(1), charlie(2).
    #expect(TranscriptDoc.blocks(from: SessionArchive.strippingFrontmatter(noteWithEmptyLine)) == [
        .heading("Transcript"),
        .paragraph("alpha widget"),
        .card("**ANSWER · a**\n\na body"),
        .card("**ANSWER · b**\n\nb body"),
        .paragraph("beta widget"),
        .paragraph("charlie widget"),
    ])
    // Correcting paragraph index 2 must hit charlie, not beta.
    let out = TranscriptCorrection.replacingOccurrence(
        0, of: "widget", with: "gadget", inParagraph: 2, ofMarkdown: noteWithEmptyLine)
    #expect(out.contains("- 17:01:00 beta widget")) // untouched
    #expect(out.contains("- 17:30:00 charlie gadget")) // corrected
}

@Test func occurrenceIndexCountsInUTF16ToMatchNSTextView() {
    // "👋" is two UTF-16 units; a selection of "cat" after it starts at offset 3.
    let text = "👋cat cat"
    #expect(TranscriptCorrection.occurrenceIndex(of: "cat", before: 2, in: text) == 0)
    #expect(TranscriptCorrection.occurrenceIndex(of: "cat", before: 6, in: text) == 1)
}

@Test func phraseStraddlingTwoStringsIsNotMatched() {
    // Documents the limitation: a phrase split across a join boundary (two
    // utterances / two lines) is out of scope — counted per-string, so not found.
    #expect(
        TranscriptCorrection.replacingOccurrence(0, of: "cat fish", with: "x", in: ["a cat", "fish"])
            == nil)
}
