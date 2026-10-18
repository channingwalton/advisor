import Foundation
import Testing

@testable import Advisor

private let markdown = """
---
started: 2026-06-18T17:00:00Z
ended: 2026-06-18T17:34:00Z
context: Pane edit test
---

# Transcript

- 17:00:00 OCaml is adopting effect systems.

- 17:00:05 More discussion follows.
"""

/// `markdown` saved in a fresh temp folder, and the detail the pane is built from.
private func savedNote() throws -> (file: SessionFile, detail: SessionDetail, dir: URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-detail-pane-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let name = "2026-06-18-170000.md"
    let url = dir.appendingPathComponent(name)
    try markdown.write(to: url, atomically: true, encoding: .utf8)
    let file = SessionFile(url: url, date: try #require(SessionArchive.date(from: name)), folder: nil)
    return (file, SessionDetail.parse(contents: markdown, fallbackTitle: name), dir)
}

/// "Add note here…" on a paragraph whose id isn't one of this detail's block
/// offsets — past the end, negative, or not a number — reports the edit as not
/// applied, so the pane takes its edit-failed reload path, and leaves the note
/// alone, rather than trapping on an index out of range (issue #84).
@MainActor
@Test(arguments: ["3", "99", "-1", "x"])
func addNoteOnAParagraphOutsideTheBlocksIsNotApplied(id: String) throws {
    let (file, detail, dir) = try savedNote()
    defer { try? FileManager.default.removeItem(at: dir) }
    try #require(detail.blocks.count == 3) // the heading and two paragraphs, so "3" is one past the end

    let applied = SessionDetailPane.addNote(
        "A note", atCharacter: 0, in: FeedParagraph(id: id, lines: [], time: nil), of: detail.blocks,
        to: file)

    #expect(!applied)
    #expect(try String(contentsOf: file.url, encoding: .utf8) == markdown)
}

/// The guard doesn't stop a note on a paragraph that is there, and the note
/// lands under that paragraph's line, not a neighbour's.
@MainActor
@Test func addNoteOnASavedParagraphWritesItIntoTheNote() throws {
    let (file, detail, dir) = try savedNote()
    defer { try? FileManager.default.removeItem(at: dir) }
    let paragraph = try #require(detail.blocks.firstIndex {
        if case .paragraph = $0 { true } else { false }
    })

    let applied = SessionDetailPane.addNote(
        "Check the figures", atCharacter: 0, in: FeedParagraph(id: "\(paragraph)", lines: [], time: nil),
        of: detail.blocks, to: file)

    let expected = try #require(NoteEdit.insertingNote(
        "Check the figures", inParagraphAt: paragraph, expecting: detail.blocks[paragraph], atCharacter: 0,
        in: markdown))
    #expect(applied)
    #expect(try String(contentsOf: file.url, encoding: .utf8) == expected)
}
