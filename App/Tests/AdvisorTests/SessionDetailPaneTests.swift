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

/// A note from the Note button lands after the transcript's last line (issue
/// #104), following the note if it has been moved meanwhile.
@MainActor
@Test func appendNoteEndsTheTranscriptOfAMovedNote() throws {
    let (file, _, dir) = try savedNote()
    defer { try? FileManager.default.removeItem(at: dir) }
    let moved = try moveIntoFolder(file, in: dir)

    let applied = SessionDetailPane.appendNote("Check the figures", to: file, archive: dir)

    let expected = try #require(NoteEdit.appendingNote("Check the figures", in: markdown))
    #expect(applied)
    #expect(try String(contentsOf: moved, encoding: .utf8) == expected)
    #expect(expected.hasSuffix("- 17:00:05 More discussion follows.\n\n> **NOTE**\n>\n> Check the figures"))
}

/// A right-clicked note's paragraph is found again by its text, nearest where it
/// was, when an edit made while the Note popover was open — a research card
/// saved above it — has shifted the offsets; nil once it has gone.
@Test func aNotePlacementFollowsItsParagraph() {
    let p = FeedParagraph(id: "1", lines: [FeedLine(id: "1", text: "Second.")], time: nil)
    let placement = NotePlacement(offset: 3, paragraph: p)
    let shifted: [TranscriptBlock] = [
        .paragraph("First."), .card("> **CONTEXT · X**"), .paragraph("Second."), .paragraph("Second."),
    ]

    #expect(SessionDetailPane.paragraph(for: placement, in: shifted)?.id == "2")
    #expect(SessionDetailPane.paragraph(for: placement, in: [.paragraph("First.")]) == nil)
}

/// Copies of the paragraph's text equally near where it was are told apart by
/// its margin time, so a short line like "Okay." isn't swapped for another.
@Test func aNotePlacementTellsCopiesOfItsParagraphApartByTime() {
    let p = FeedParagraph(id: "2", lines: [FeedLine(id: "2", text: "Okay.")], time: "10:05")
    let placement = NotePlacement(offset: 0, paragraph: p)
    let blocks: [TranscriptBlock] = [.heading("Transcript"), .paragraph("Okay."), .card("> **CONTEXT · X**"), .paragraph("Okay.")]

    #expect(SessionDetailPane.paragraph(for: placement, in: blocks, times: [nil, "10:01", nil, "10:05"])?.id == "3")
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
    let moved = try moveIntoFolder(file, in: dir)

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

/// `file` moved into a folder since the pane loaded — from outside the app, so
/// the pane still holds the old URL. A bare move on purpose, as Finder would do
/// it, rather than `SessionArchive.setFolder`: the app's own filing re-points
/// the pane and never hits this path.
private func moveIntoFolder(_ file: SessionFile, in dir: URL) throws -> URL {
    let folder = dir.appendingPathComponent("Work")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let moved = folder.appendingPathComponent(file.url.lastPathComponent)
    try FileManager.default.moveItem(at: file.url, to: moved)
    return moved
}

/// "Add note here…" on a session moved into a folder from outside the app since
/// the pane loaded follows the note there, rather than finding nothing at the
/// old path and dropping the typed note on the edit-failed path (issue #94).
@MainActor
@Test func addNoteFollowsAMovedNote() throws {
    let (file, detail, dir) = try savedNote()
    defer { try? FileManager.default.removeItem(at: dir) }
    let moved = try moveIntoFolder(file, in: dir)

    let applied = SessionDetailPane.addNote(
        "Check the figures", atCharacter: 0, in: row("1"), of: detail.blocks, to: file, archive: dir)

    let expected = try #require(NoteEdit.insertingNote(
        "Check the figures", inParagraphAt: 1, expecting: detail.blocks[1], atCharacter: 0, in: markdown))
    #expect(applied)
    #expect(try String(contentsOf: moved, encoding: .utf8) == expected)
    #expect(!FileManager.default.fileExists(atPath: file.url.path))
}

/// Delete on a note of a session moved into a folder from outside the app since
/// the pane loaded follows the note there too (issue #94).
@MainActor
@Test func deletingABlockFollowsAMovedNote() throws {
    let withNote = markdown + "\n> **NOTE**\n>\n> Check the figures\n"
    let (file, detail, dir) = try savedNote(withNote)
    defer { try? FileManager.default.removeItem(at: dir) }
    let offset = try #require(detail.blocks.firstIndex { if case .note = $0 { true } else { false } })
    let moved = try moveIntoFolder(file, in: dir)

    let applied = SessionDetailPane.removeBlock(at: offset, of: detail.blocks, from: file, archive: dir)

    let expected = try #require(NoteEdit.removingBlock(at: offset, expecting: detail.blocks[offset], in: withNote))
    #expect(applied)
    #expect(try String(contentsOf: moved, encoding: .utf8) == expected)
    #expect(!FileManager.default.fileExists(atPath: file.url.path))
}

/// Summarise, Ask, a follow-up or a research card on a session moved into a
/// folder from outside the app since the pane loaded sends the note there, not
/// "" at the old path. A research card finds its line in it. A summary saved
/// to the note that was sent replaces its old summary and keeps its transcript
/// (issue #115).
@MainActor
@Test func aRequestOnAMovedNoteSendsTheNoteWhereItIsNow() throws {
    let withSummary = SessionArchive.upsertingSummary(into: markdown, summary: "The old summary.")
    let (file, detail, dir) = try savedNote(withSummary)
    defer { try? FileManager.default.removeItem(at: dir) }
    let moved = try moveIntoFolder(file, in: dir)
    #expect(SessionArchive.contents(of: file) == "") // the read before #115

    var sent: (note: SessionFile, markdown: String)?
    let started = SessionDetailPane.startRequest(on: file, archive: dir) { note, markdown in
        sent = (note, markdown)
        return .sent("request")
    }

    #expect(started == .sent("request"))
    let note = try #require(sent?.note)
    #expect(note.folder == "Work")
    #expect(sent?.markdown == withSummary)
    let paragraph = try #require(detail.blocks.firstIndex { if case .paragraph = $0 { true } else { false } })
    #expect(NoteEdit.anchor(ofParagraphAt: paragraph, expecting: detail.blocks[paragraph], in: withSummary) != nil)

    #expect(SessionArchive.save(to: note, in: dir) { SessionArchive.upsertSummary("The new summary.", to: $0) })
    let saved = try String(contentsOf: moved, encoding: .utf8)
    #expect(saved == SessionArchive.upsertingSummary(into: withSummary, summary: "The new summary."))
    #expect(saved.contains("- 17:00:00 OCaml is adopting effect systems."))
    #expect(!saved.contains("The old summary."))
    #expect(!FileManager.default.fileExists(atPath: file.url.path))
}

/// Summarise, Ask, a follow-up or a research card on a session deleted from
/// outside the app since the pane loaded sends nothing: `send` is not called,
/// so no request runs and no answer can be saved. The pane shows its message
/// for `.unreadable`. No note appears at either path (issue #115).
@MainActor
@Test func aRequestOnADeletedNoteSendsNothing() throws {
    let (file, _, dir) = try savedNote()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.removeItem(at: file.url)

    var sends = 0
    let started = SessionDetailPane.startRequest(on: file, archive: dir) { _, _ in
        sends += 1
        return .sent("request")
    }

    #expect(started == .unreadable)
    #expect(sends == 0)
    #expect(SessionArchive.list(in: dir).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: file.url.path))
}

/// On a readable note, the outcome of `send` comes back as it is: a sidecar
/// that is not running, or a research line that has gone.
@MainActor
@Test func aRequestOnAReadableNoteReturnsWhatSendGives() throws {
    let (file, _, dir) = try savedNote()
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(SessionDetailPane.startRequest(on: file, archive: dir) { _, _ in NoteRequest(sent: nil) } == .notSent)
    #expect(SessionDetailPane.startRequest(on: file, archive: dir) { _, _ in .declined } == .declined)
    #expect(SessionDetailPane.startRequest(on: file, archive: dir) { _, _ in NoteRequest(sent: "r") } == .sent("r"))
}

/// A note of the same file name in a folder isn't `file` moved: a copy made
/// outside the app, or another note filed over it. With `file` gone, Add note
/// and Delete find it as the relocated note but their expected-block checks run
/// there too, so a lookalike whose blocks differ is refused, not edited.
private let lookalike = markdown.replacingOccurrences(
    of: "- 17:00:00 OCaml is adopting effect systems.",
    with: "- 17:00:00 Nothing of the sort was said.\n\n> **NOTE**\n>\n> Theirs, not ours")

@MainActor
@Test func addNoteRefusesALookalikeAtTheRelocatedPath() throws {
    let (file, detail, dir) = try savedNote()
    defer { try? FileManager.default.removeItem(at: dir) }
    let other = try moveIntoFolder(file, in: dir)
    try lookalike.write(to: other, atomically: true, encoding: .utf8)

    let applied = SessionDetailPane.addNote(
        "Check the figures", atCharacter: 0, in: row("1"), of: detail.blocks, to: file, archive: dir)

    #expect(!applied)
    #expect(try String(contentsOf: other, encoding: .utf8) == lookalike)
}

@MainActor
@Test func deletingABlockRefusesALookalikeAtTheRelocatedPath() throws {
    let withNote = markdown + "\n> **NOTE**\n>\n> Check the figures\n"
    let (file, detail, dir) = try savedNote(withNote)
    defer { try? FileManager.default.removeItem(at: dir) }
    let offset = try #require(detail.blocks.firstIndex { if case .note = $0 { true } else { false } })
    let other = try moveIntoFolder(file, in: dir)
    try lookalike.write(to: other, atomically: true, encoding: .utf8)

    let applied = SessionDetailPane.removeBlock(at: offset, of: detail.blocks, from: file, archive: dir)

    #expect(!applied)
    #expect(try String(contentsOf: other, encoding: .utf8) == lookalike)
}

/// Delete at a block offset outside `blocks` — a row out of step with the
/// detail — reports the edit as not applied and leaves the note alone, rather
/// than trapping on an index out of range.
@MainActor
@Test(arguments: [3, 99, -1])
func deletingABlockOutsideTheBlocksIsNotApplied(offset: Int) throws {
    let (file, detail, dir) = try savedNote()
    defer { try? FileManager.default.removeItem(at: dir) }
    try #require(detail.blocks.count == 3)

    let applied = SessionDetailPane.removeBlock(at: offset, of: detail.blocks, from: file, archive: dir)

    #expect(!applied)
    #expect(try String(contentsOf: file.url, encoding: .utf8) == markdown)
}
