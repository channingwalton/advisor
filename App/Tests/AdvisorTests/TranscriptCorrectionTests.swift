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

@Test func occurrenceIndexCountsInUTF16ToMatchNSTextView() {
    // "👋" is two UTF-16 units; a selection of "cat" after it starts at offset 3.
    let text = "👋cat cat"
    #expect(TranscriptCorrection.occurrenceIndex(of: "cat", before: 2, in: text) == 0)
    #expect(TranscriptCorrection.occurrenceIndex(of: "cat", before: 6, in: text) == 1)
}

// MARK: matches across a join (issue #92)

/// The paragraph shows its lines joined by single spaces, and the menu counts
/// the selection's occurrence over that text. A match that straddles a join
/// counts there too, so the edit must count the same way or every later match
/// is off by one.
private let straddling = ["this is", "a cat, this is a dog, this is a bird"]

@Test func replaceNthCountsOverTheJoinedTextTheMenuCounted() {
    // Over the joined text "is a" matches at: the join (0), "is a dog" (1),
    // "is a bird" (2).
    #expect(
        TranscriptCorrection.replacingOccurrence(1, of: "is a", with: "was a", in: straddling)
            == ["this is", "a cat, this was a dog, this is a bird"])
    #expect(
        TranscriptCorrection.replacingOccurrence(2, of: "is a", with: "was a", in: straddling)
            == ["this is", "a cat, this is a dog, this was a bird"])
}

@Test func replaceNthRefusesAMatchAcrossAJoin() {
    // The match lies in neither line, so it isn't corrected — not miscounted.
    #expect(TranscriptCorrection.replacingOccurrence(0, of: "is a", with: "x", in: straddling) == nil)
    #expect(
        TranscriptCorrection.replacingOccurrence(0, of: "cat fish", with: "x", in: ["a cat", "fish"])
            == nil)
    // A join is one space: a phrase with two spaces across it doesn't match.
    #expect(TranscriptCorrection.replacingOccurrence(0, of: "cat  fish", with: "x", in: ["a cat", "fish"]) == nil)
}

@Test func locationOfAnOccurrenceNamesItsLineOrNilAcrossAJoin() {
    #expect(TranscriptCorrection.location(ofOccurrence: 0, of: "is a", in: straddling) == nil)
    #expect(
        TranscriptCorrection.location(ofOccurrence: 1, of: "is a", in: straddling)
            == TranscriptCorrection.OccurrenceLocation(line: 1, range: NSRange(location: 12, length: 4)))
    #expect(
        TranscriptCorrection.location(ofOccurrence: 0, of: "this", in: straddling)
            == TranscriptCorrection.OccurrenceLocation(line: 0, range: NSRange(location: 0, length: 4)))
    // Edges of a line, and an occurrence that isn't there.
    #expect(
        TranscriptCorrection.location(ofOccurrence: 1, of: "a bird", in: straddling)?.line == nil)
    #expect(
        TranscriptCorrection.location(ofOccurrence: 0, of: "a bird", in: straddling)
            == TranscriptCorrection.OccurrenceLocation(line: 1, range: NSRange(location: 30, length: 6)))
    // Starts on the join space itself: in no line.
    #expect(TranscriptCorrection.location(ofOccurrence: 0, of: " a cat", in: straddling) == nil)
    #expect(TranscriptCorrection.location(ofOccurrence: 0, of: "", in: straddling) == nil)
    #expect(TranscriptCorrection.location(ofOccurrence: -1, of: "is", in: straddling) == nil)
}

@Test func rangeOfAnOccurrenceFindsTheMenusMatchEvenAcrossAJoin() {
    let joined = straddling.joined(separator: " ")
    #expect(TranscriptCorrection.range(ofOccurrence: 0, of: "is a", in: joined) == NSRange(location: 5, length: 4))
    #expect(TranscriptCorrection.range(ofOccurrence: 2, of: "is a", in: joined) == NSRange(location: 35, length: 4))
    #expect(TranscriptCorrection.range(ofOccurrence: 3, of: "is a", in: joined) == nil)
    // The second "aa" of "aaa" overlaps the first: not a non-overlapping match.
    #expect(TranscriptCorrection.range(ofOccurrence: 1, of: "aa", in: "aaa") == nil)
    #expect(TranscriptCorrection.range(ofOccurrence: 0, of: "", in: "aaa") == nil)
}

@Test func locationCountsInUTF16LikeTheMenu() {
    // "👋" is two UTF-16 units, so the second line's offsets shift by two.
    let texts = ["👋 cat", "cat"]
    #expect(
        TranscriptCorrection.location(ofOccurrence: 1, of: "cat", in: texts)
            == TranscriptCorrection.OccurrenceLocation(line: 1, range: NSRange(location: 0, length: 3)))
    #expect(
        TranscriptCorrection.location(ofOccurrence: 0, of: "cat", in: texts)
            == TranscriptCorrection.OccurrenceLocation(line: 0, range: NSRange(location: 3, length: 3)))
}

// MARK: an indented line (issue #93)

/// A hand-edited note can indent a transcript line; Advisor never writes one.
/// `TranscriptDoc` trims the line before looking for its bullet, so the stamp
/// is still a stamp there, and Replace all must read it the same way: only the
/// text after the stamp is replaceable, however the line is indented.
@Test func replaceAllInTranscriptLeavesTheStampOfAnIndentedLine() {
    let note = """
        # Transcript

        - 17:00:00 alpha 17

          - 17:00:30 beta effect 17

          - stampless 17

          prose 17
        """
    let out = TranscriptCorrection.replacingAllInTranscript(of: "17", with: "18", inMarkdown: note)
    #expect(
        out == """
            # Transcript

            - 17:00:00 alpha 18

              - 17:00:30 beta effect 18

              - stampless 18

              prose 18
            """)
}
