import Foundation

/// Pure edits to a saved session note, addressed by `TranscriptDoc` block offset —
/// what the Sessions detail does to a note when its feed is acted on. Each takes
/// the block it expects at that offset and returns nil when the note no longer
/// matches (it changed since the detail was read), so a stale view can't edit
/// the wrong block. Frontmatter is preserved verbatim.
enum NoteEdit {
    /// `markdown` without the card or editorial note at block `offset`. A
    /// `# Summary` or `# Follow-ups` section left empty goes too; the transcript
    /// and the user's own headings always stay. Paragraphs and headings can't be
    /// removed.
    static func removingBlock(at offset: Int, expecting expected: TranscriptBlock, in markdown: String) -> String? {
        switch expected {
        case .card, .note: break
        case .paragraph, .heading: return nil
        }
        let (prefix, body) = TranscriptDoc.splitFrontmatter(markdown)
        let blocks = TranscriptDoc.timedBlocks(from: body)
        guard blocks.indices.contains(offset), blocks[offset].block == expected,
            let first = blocks[offset].lines.first, let last = blocks[offset].lines.last
        else { return nil }

        var lines = body.components(separatedBy: "\n")
        lines.removeSubrange(first...last)
        var splice = first

        // The section the block sat in, if it's one Advisor writes (Summary,
        // Follow-ups) and removing the block left it with only blank lines.
        if let heading = lines[..<splice].lastIndex(where: isHeading),
            removableSections.contains(trimmed(lines[heading]))
        {
            let end = lines[(heading + 1)...].firstIndex(where: isHeading) ?? lines.count
            if lines[(heading + 1)..<end].allSatisfy(isBlank) {
                lines.removeSubrange(heading..<end)
                splice = heading
            }
        }
        // Blocks are blank-line separated; don't leave two blanks where one was,
        // or a blank at the top of the body.
        if splice == 0 {
            while let first = lines.first, isBlank(first), lines.count > 1 { lines.removeFirst() }
        }
        while splice > 0, splice < lines.count, isBlank(lines[splice - 1]), isBlank(lines[splice]) {
            lines.remove(at: splice)
        }
        return prefix + lines.joined(separator: "\n")
    }

    /// `markdown` with an editorial note (issue #34) inserted after the transcript
    /// line that character `offset` of the paragraph at block `paragraphOffset`
    /// falls in — where "Add note here…" was chosen, as live — so it splits the
    /// paragraph there, after any notes already on that line and above any card
    /// under it.
    /// Nil for blank text or a block that isn't the expected paragraph.
    static func insertingNote(
        _ text: String, inParagraphAt paragraphOffset: Int, expecting expected: TranscriptBlock,
        atCharacter offset: Int, in markdown: String
    ) -> String? {
        guard case .paragraph = expected, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let (prefix, body) = TranscriptDoc.splitFrontmatter(markdown)
        let blocks = TranscriptDoc.timedBlocks(from: body)
        guard blocks.indices.contains(paragraphOffset), blocks[paragraphOffset].block == expected else {
            return nil
        }
        var lines = body.components(separatedBy: "\n")
        let members = blocks[paragraphOffset].lines
        guard let member = NoteAnchor.lineIndex(
            forOffset: offset, in: members.map { TranscriptDoc.memberText(lines[$0]) })
        else { return nil }

        // Below notes already on that line (oldest first, as live) but above any
        // card under it — live, a note sorts before a card at the same time.
        var at = members[member] + 1
        var next = at
        while next < lines.count, isBlank(lines[next]) || lines[next] == "> **NOTE**" {
            if isBlank(lines[next]) {
                next += 1
                continue
            }
            while next < lines.count, lines[next].hasPrefix(">") { next += 1 }
            at = next
        }
        var insert = [""] + SessionMarkdown.noteBlock(text).components(separatedBy: "\n")
        if at < lines.count, !isBlank(lines[at]) { insert.append("") }
        lines.insert(contentsOf: insert, at: at)
        return prefix + lines.joined(separator: "\n")
    }

    /// `markdown` with the `n`-th occurrence of `original` in the paragraph at
    /// block `offset` replaced by `replacement` — "Correct transcription…" on that
    /// row. Only the text of the paragraph's own lines changes, counted line by
    /// line (`TranscriptCorrection.replacingOccurrence`); bullets and stamps stay.
    /// Nil for a block that isn't the expected paragraph, or when there is no
    /// `n`-th occurrence within one of its lines.
    static func correctingOccurrence(
        _ n: Int, of original: String, with replacement: String, inParagraphAt offset: Int,
        expecting expected: TranscriptBlock, in markdown: String
    ) -> String? {
        guard case .paragraph = expected else { return nil }
        let (prefix, body) = TranscriptDoc.splitFrontmatter(markdown)
        let blocks = TranscriptDoc.timedBlocks(from: body)
        guard blocks.indices.contains(offset), blocks[offset].block == expected else { return nil }
        var lines = body.components(separatedBy: "\n")
        let members = blocks[offset].lines
        let texts = members.map { TranscriptDoc.memberText(lines[$0]) }
        guard let corrected = TranscriptCorrection.replacingOccurrence(n, of: original, with: replacement, in: texts)
        else { return nil }
        for (slot, index) in members.enumerated() where corrected[slot] != texts[slot] {
            // A member's text ends its line, bar trailing whitespace.
            guard let range = lines[index].range(of: texts[slot], options: .backwards) else { return nil }
            lines[index].replaceSubrange(range, with: corrected[slot])
        }
        return prefix + lines.joined(separator: "\n")
    }

    /// A transcript line a card will be placed under: its body line index when
    /// it was chosen, and the line itself, so it can be found again after other
    /// edits have moved it.
    struct Anchor: Equatable {
        let index: Int
        let line: String
    }

    /// The last line of the paragraph at block `offset` — where a research card
    /// on that paragraph goes, as live cards anchor under its last utterance.
    static func anchor(ofParagraphAt offset: Int, expecting expected: TranscriptBlock, in markdown: String) -> Anchor? {
        guard case .paragraph = expected else { return nil }
        let body = TranscriptDoc.splitFrontmatter(markdown).body
        let blocks = TranscriptDoc.timedBlocks(from: body)
        guard blocks.indices.contains(offset), blocks[offset].block == expected,
            let last = blocks[offset].lines.last
        else { return nil }
        return Anchor(index: last, line: body.components(separatedBy: "\n")[last])
    }

    /// `markdown` with a card `block` (`SessionMarkdown.cardBlock`) inserted under
    /// `anchor`'s line, below any cards or notes already there — it's newer than
    /// them, as in the live feed. The line is found by its text, nearest where it
    /// was, so edits made meanwhile don't misplace it; failing that (a correction
    /// changed it) by its timestamp; failing that, the card goes under the last
    /// transcript line, ending the transcript, rather than being lost.
    static func insertingBlock(_ block: String, after anchor: Anchor, in markdown: String) -> String {
        let (prefix, body) = TranscriptDoc.splitFrontmatter(markdown)
        var lines = body.components(separatedBy: "\n")
        func nearest(_ candidates: [Int]) -> Int? {
            candidates.min { abs($0 - anchor.index) < abs($1 - anchor.index) }
        }
        let stamp = stampPrefix(anchor.line)
        // The transcript's end is its last paragraph line, wherever the headings
        // fall — a user's own heading can sit inside it, and a summary after it.
        let lastTranscriptLine = TranscriptDoc.timedBlocks(from: body).last {
            if case .paragraph = $0.block { true } else { false }
        }?.lines.last
        let line = nearest(lines.indices.filter { lines[$0] == anchor.line })
            ?? stamp.flatMap { stamp in nearest(lines.indices.filter { stampPrefix(lines[$0]) == stamp }) }
            ?? lastTranscriptLine

        var at: Int
        if let line {
            at = line + 1
            var next = at
            while next < lines.count, isBlank(lines[next]) || lines[next].hasPrefix(">") {
                if lines[next].hasPrefix(">") { at = next + 1 }
                next += 1
            }
        } else {
            // No transcript at all: the end of the note.
            at = lines.count
            while at > 0, isBlank(lines[at - 1]) { at -= 1 }
        }
        var insert = (at > 0 ? [""] : []) + block.components(separatedBy: "\n")
        if at < lines.count, !isBlank(lines[at]) { insert.append("") }
        lines.insert(contentsOf: insert, at: at)
        return prefix + lines.joined(separator: "\n")
    }

    /// The id (`Feed.savedIds`) of the card whose body contains `body` — a card
    /// just rewritten with a follow-up, whose content id has changed.
    static func cardId(withBody body: String, in markdown: String) -> String? {
        let blocks = TranscriptDoc.blocks(from: TranscriptDoc.splitFrontmatter(markdown).body)
        guard let index = blocks.firstIndex(where: { if case .card(let m) = $0 { m.contains(body) } else { false } })
        else { return nil }
        return Feed.savedIds(blocks)[index]
    }

    /// The block offset of the paragraph whose last line is `line` (an
    /// `Anchor.line`), nearest `near` — where an in-flight research card shows
    /// while other edits shift block offsets. Failing that (a correction changed
    /// the line), the paragraph nearest `near`, so the card stays in the
    /// transcript, as its save will; nil only when there are no paragraphs.
    static func paragraphOffset(endingWith line: String, near: Int, in blocks: [TranscriptBlock]) -> Int? {
        let text = TranscriptDoc.memberText(line)
        func nearest(_ candidates: [Int]) -> Int? { candidates.min { abs($0 - near) < abs($1 - near) } }
        let paragraphs = blocks.indices.filter { if case .paragraph = blocks[$0] { true } else { false } }
        return nearest(paragraphs.filter { index in
            guard case .paragraph(let paragraph) = blocks[index] else { return false }
            return paragraph == text || paragraph.hasSuffix(" " + text)
        }) ?? nearest(paragraphs)
    }

    /// A transcript line's `- HH:MM:SS` prefix, or nil for an unstamped line.
    private static func stampPrefix(_ line: String) -> Substring? {
        let stamp = line.dropFirst(2).prefix(8)
        guard line.hasPrefix("- "), stamp.count == 8,
            stamp.enumerated().allSatisfy({ i, c in i == 2 || i == 5 ? c == ":" : c.isASCII && c.isNumber })
        else { return nil }
        return line.prefix(10)
    }

    /// `markdown` with the body of the card whose `Feed.savedIds` id is `id`
    /// changed from `old` (as `SavedCard` parsed it) to `new` — a follow-up
    /// appended — keeping its header and footer. The card is found by id, which
    /// follows its content, so other edits made meanwhile don't misplace it; nil
    /// when it has gone or changed.
    static func replacingCardBody(ofCard id: String, body old: String, with new: String, in markdown: String) -> String? {
        let (prefix, body) = TranscriptDoc.splitFrontmatter(markdown)
        let blocks = TranscriptDoc.timedBlocks(from: body)
        guard let offset = Feed.savedIds(blocks.map(\.block)).firstIndex(of: id),
            case .card(let inner) = blocks[offset].block,
            let first = blocks[offset].lines.first, let last = blocks[offset].lines.last
        else { return nil }

        let updated: String
        if old.isEmpty {
            // No body yet: the follow-up goes straight under the header.
            var innerLines = inner.components(separatedBy: "\n")
            innerLines.insert(contentsOf: ["", new], at: min(1, innerLines.count))
            updated = innerLines.joined(separator: "\n")
        } else {
            // The body follows the header line, so search past it.
            let afterHeader = inner.firstIndex(of: "\n") ?? inner.startIndex
            guard let range = inner.range(of: old, range: afterHeader..<inner.endIndex) else { return nil }
            updated = inner.replacingCharacters(in: range, with: new)
        }

        var lines = body.components(separatedBy: "\n")
        lines.replaceSubrange(
            first...last, with: updated.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> \($0)" })
        return prefix + lines.joined(separator: "\n")
    }

    /// The sections a delete may remove once empty — the ones Advisor itself
    /// writes around cards. The transcript and the user's own headings stay.
    private static let removableSections: Set<String> = ["# Summary", "# Follow-ups"]

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A heading line, as `TranscriptDoc` reads one.
    private static func isHeading(_ line: String) -> Bool {
        trimmed(line).hasPrefix("# ")
    }

    private static func trimmed(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }
}
