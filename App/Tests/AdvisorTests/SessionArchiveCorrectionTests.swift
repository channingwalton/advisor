import Foundation
import Testing

@testable import Advisor

/// Writes `markdown` to a throwaway session note and returns its `SessionFile`.
/// The directory is removed by the caller's `defer`.
private func makeNote(_ markdown: String, in dir: URL) throws -> SessionFile {
    let url = dir.appendingPathComponent("2026-06-22-170000.md")
    try markdown.write(to: url, atomically: true, encoding: .utf8)
    return try #require(SessionArchive.list(in: dir).first)
}

private let note = """
---
started: 2026-06-22T17:00:00Z
context: meeting about widgets
---

# Transcript

- 17:00:00 hello widgets are great

- 17:00:01 widgets again

> **ANSWER · Title**
>
> widgets in card body
"""

private func blocks(_ markdown: String) -> [TranscriptBlock] {
    TranscriptDoc.blocks(from: SessionArchive.strippingFrontmatter(markdown))
}

@Test func correctAllRewritesTranscriptOnly() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-correct-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = try makeNote(note, in: dir)
    #expect(SessionArchive.correctAll(of: "widgets", with: "gadgets", in: file))

    let out = SessionArchive.contents(of: file)
    #expect(out.contains("- 17:00:00 hello gadgets are great"))
    #expect(out.contains("- 17:00:01 gadgets again"))
    #expect(out.contains("context: meeting about widgets")) // frontmatter intact
    #expect(out.contains("> widgets in card body")) // card intact
}

@Test func correctOccurrenceRewritesOneLine() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-correct-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = try makeNote(note, in: dir)
    // The paragraph after the heading, occurrence 1 → the "widgets again" line.
    let paragraph = blocks(note)[1]
    #expect(
        SessionArchive.correctOccurrence(
            1, of: "widgets", with: "gadgets", inParagraphAt: 1, expecting: paragraph, of: file))

    let out = SessionArchive.contents(of: file)
    #expect(out.contains("- 17:00:00 hello widgets are great")) // untouched
    #expect(out.contains("- 17:00:01 gadgets again")) // corrected
}

@Test func correctReturnsFalseWhenNothingMatches() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-correct-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = try makeNote(note, in: dir)
    #expect(!SessionArchive.correctAll(of: "absent", with: "x", in: file))
    #expect(
        !SessionArchive.correctOccurrence(
            0, of: "absent", with: "x", inParagraphAt: 1, expecting: blocks(note)[1], of: file))
    #expect(SessionArchive.contents(of: file) == note)
}
