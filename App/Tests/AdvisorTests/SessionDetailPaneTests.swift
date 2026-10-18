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

/// `contents` saved in a fresh temp folder, and the detail the pane is built from.
private func savedNote(_ contents: String = markdown) throws -> (file: SessionFile, detail: SessionDetail, dir: URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-detail-pane-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let name = "2026-06-18-170000.md"
    let url = dir.appendingPathComponent(name)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    let file = SessionFile(url: url, date: try #require(SessionArchive.date(from: name)), folder: nil)
    return (file, SessionDetail.parse(contents: contents, fallbackTitle: name), dir)
}

/// A row of the saved feed: its id is its block offset.
private func row(_ id: String) -> FeedParagraph { FeedParagraph(id: id, lines: [], time: nil) }

/// "Correct transcription…" of the first `original` in the row to `replacement`.
private func correction(
    _ original: String, to replacement: String, _ scope: TranscriptCorrectionRequest.Scope
) -> TranscriptCorrectionRequest {
    TranscriptCorrectionRequest(
        original: original, replacement: replacement, occurrenceInParagraph: 0, scope: scope)
}

/// "Add note here…" on a paragraph whose id doesn't name one of this detail's
/// paragraphs — the heading, past the end, negative, or not a number — reports
/// the edit as not applied, so the pane takes its edit-failed reload path, and
/// leaves the note alone, rather than trapping on an index out of range (issue
/// #84).
@MainActor
@Test(arguments: ["0", "3", "99", "-1", "x"])
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

/// "Correct transcription…" on a paragraph whose id doesn't name one of this
/// detail's paragraphs — the heading, past the end, negative, or not a number —
/// isn't applied, for either scope, so the pane takes its edit-failed reload path
/// rather than trapping on a slice out of range, or correcting the paragraph
/// after the heading (issue #90).
@MainActor
@Test(arguments: ["0", "3", "99", "-1", "x"], [TranscriptCorrectionRequest.Scope.thisOccurrence, .allInSession])
func aCorrectionOnAParagraphOutsideTheBlocksIsNotApplied(id: String, scope: TranscriptCorrectionRequest.Scope) throws {
    let (file, detail, dir) = try savedNote()
    defer { try? FileManager.default.removeItem(at: dir) }
    try #require(detail.blocks.count == 3) // the heading and two paragraphs, so "3" is one past the end

    let applied = SessionDetailPane.correct(
        correction("effect", to: "affect", scope), in: row(id), of: detail.blocks, to: file, archive: dir)

    #expect(!applied)
    #expect(try String(contentsOf: file.url, encoding: .utf8) == markdown)
}

/// "This occurrence" corrects the row's own paragraph: the second one here, past
/// the heading, which the paragraph count skips.
@MainActor
@Test func correctingThisOccurrenceRewritesTheRowsParagraph() throws {
    let (file, detail, dir) = try savedNote()
    defer { try? FileManager.default.removeItem(at: dir) }

    let applied = SessionDetailPane.correct(
        correction("discussion", to: "debate", .thisOccurrence), in: row("2"), of: detail.blocks, to: file,
        archive: dir)

    #expect(applied)
    #expect(try String(contentsOf: file.url, encoding: .utf8)
        == markdown.replacingOccurrences(of: "More discussion", with: "More debate"))
}

/// A row out of step with the note — a paragraph added on disk ahead of it since
/// the pane loaded — isn't corrected: the paragraph at its offset is no longer
/// the one shown, and the match in whichever paragraph now has its ordinal would
/// be rewritten instead, silently (issue #91).
@MainActor
@Test func correctingThisOccurrenceOnAStaleRowIsNotApplied() throws {
    let (file, detail, dir) = try savedNote()
    defer { try? FileManager.default.removeItem(at: dir) }
    let edited = markdown.replacingOccurrences(
        of: "- 17:00:00 OCaml", with: "- 16:59:00 Earlier, effect systems came up.\n\n- 17:00:00 OCaml")
    try edited.write(to: file.url, atomically: true, encoding: .utf8)

    let applied = SessionDetailPane.correct(
        correction("effect", to: "affect", .thisOccurrence), in: row("1"), of: detail.blocks, to: file,
        archive: dir)

    #expect(!applied)
    #expect(try String(contentsOf: file.url, encoding: .utf8) == edited)
}

/// A correction on a session filed into a folder since the pane loaded follows
/// the note there, for either scope, rather than reading the old path, finding
/// nothing and saying nothing (issue #91).
@MainActor
@Test(arguments: [TranscriptCorrectionRequest.Scope.thisOccurrence, .allInSession])
func aCorrectionFollowsAMovedNote(scope: TranscriptCorrectionRequest.Scope) throws {
    let (file, detail, dir) = try savedNote()
    defer { try? FileManager.default.removeItem(at: dir) }
    let folder = dir.appendingPathComponent("Work")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let moved = folder.appendingPathComponent(file.url.lastPathComponent)
    try FileManager.default.moveItem(at: file.url, to: moved)

    let applied = SessionDetailPane.correct(
        correction("effect", to: "affect", scope), in: row("1"), of: detail.blocks, to: file, archive: dir)

    #expect(applied)
    #expect(try String(contentsOf: moved, encoding: .utf8)
        == markdown.replacingOccurrences(of: "effect", with: "affect"))
    #expect(!FileManager.default.fileExists(atPath: file.url.path))
}

/// A selection that spans two transcript lines reads as one phrase in the
/// paragraph but matches neither line, so a correction of it changes nothing.
/// That isn't applied either, for either scope, so the pane says the note wasn't
/// updated rather than doing nothing (issue #91).
@MainActor
@Test(arguments: [TranscriptCorrectionRequest.Scope.thisOccurrence, .allInSession])
func aCorrectionThatChangesNothingIsNotApplied(scope: TranscriptCorrectionRequest.Scope) throws {
    let twoLines = markdown.replacingOccurrences(
        of: "- 17:00:00 OCaml is adopting effect systems.",
        with: "- 17:00:00 OCaml is adopting\n- 17:00:01 effect systems.")
    let (file, detail, dir) = try savedNote(twoLines)
    defer { try? FileManager.default.removeItem(at: dir) }
    try #require(detail.blocks[1] == .paragraph("OCaml is adopting effect systems."))

    let applied = SessionDetailPane.correct(
        correction("adopting effect", to: "adopting affect", scope), in: row("1"), of: detail.blocks, to: file,
        archive: dir)

    #expect(!applied)
    #expect(try String(contentsOf: file.url, encoding: .utf8) == twoLines)
}
