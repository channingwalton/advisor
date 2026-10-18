import Foundation

/// Pure text-correction primitives shared by the live feed (in-memory
/// `Utterance`s) and the saved-session browser (markdown file). Everything here
/// operates on plain strings so it is unit-testable without the UI.
///
/// Matching is literal and case-sensitive: `original` is the exact highlighted
/// span. Occurrence counting is non-overlapping, left-to-right, and UTF-16-based
/// so it lines up with the selection offsets `NSTextView` reports.
///
/// A paragraph shows its lines (utterances) joined by single spaces, and the
/// menu counts the selected occurrence over that text, so single-occurrence
/// correction counts the same way (`location(ofOccurrence:of:in:)`) and then
/// edits the one line the match lies in. A match across a join lies in neither
/// line and is refused rather than corrected or miscounted; the menu doesn't
/// offer it. Whole-session replace works line by line and leaves such matches
/// (DESIGN.md, issue #92).
enum TranscriptCorrection {

    // MARK: occurrence counting

    /// 0-based occurrence index of a selection of `original` that starts at UTF-16
    /// offset `location` in `text` — i.e. how many non-overlapping occurrences of
    /// `original` begin strictly before `location`. Empty `original` → 0.
    static func occurrenceIndex(of original: String, before location: Int, in text: String) -> Int {
        var count = 0
        for range in nonOverlappingRanges(of: original, in: text) {
            guard range.location < location else { break }
            count += 1
        }
        return count
    }

    /// The non-overlapping matches of `original` in `text`, left to right, as
    /// UTF-16 ranges — the one walk every count and lookup here is taken from, so
    /// they can't disagree. Empty `original` → no matches.
    private static func nonOverlappingRanges(of original: String, in text: String) -> [NSRange] {
        guard !original.isEmpty else { return [] }
        let ns = text as NSString
        var ranges: [NSRange] = []
        var searchStart = 0
        while searchStart <= ns.length {
            let range = ns.range(
                of: original, options: [],
                range: NSRange(location: searchStart, length: ns.length - searchStart))
            guard range.location != NSNotFound else { break }
            ranges.append(range)
            searchStart = range.location + max(range.length, 1)
        }
        return ranges
    }

    // MARK: locating an occurrence in a paragraph's lines

    /// Where an occurrence lies: the index of the line in `texts` and its UTF-16
    /// range within that line.
    struct OccurrenceLocation: Equatable {
        let line: Int
        let range: NSRange
    }

    /// The `n`-th (0-based) non-overlapping occurrence of `original` in `texts`
    /// joined by single spaces — the paragraph as shown, which is what
    /// `occurrenceIndex` counted the selection against — mapped back to the line
    /// it lies in. Nil when `original` is empty, `n` is negative, there is no
    /// `n`-th occurrence, or it crosses a join, so lies in no one line.
    static func location(ofOccurrence n: Int, of original: String, in texts: [String]) -> OccurrenceLocation? {
        guard let match = range(ofOccurrence: n, of: original, in: texts.joined(separator: " ")) else { return nil }
        // Walk the lines to the one the match starts in; it must also end there.
        // A match starting on a join space starts in no line.
        var lineStart = 0
        for (index, text) in texts.enumerated() {
            let length = (text as NSString).length
            if match.location < lineStart + length {
                guard match.location >= lineStart, match.location + match.length <= lineStart + length
                else { return nil }
                return OccurrenceLocation(
                    line: index, range: NSRange(location: match.location - lineStart, length: match.length))
            }
            lineStart += length + 1
        }
        return nil
    }

    /// The UTF-16 range of the `n`-th (0-based) non-overlapping occurrence of
    /// `original` in `text`, or nil when `original` is empty, `n` is negative, or
    /// there is no `n`-th occurrence. Over a paragraph's joined text this is the
    /// match the menu's `occurrenceIndex` counted to — found even when it crosses
    /// a join, which `location(ofOccurrence:of:in:)` then refuses. Nil here means
    /// the selection isn't the `n`-th match at all: it overlaps an earlier match
    /// of itself, as the second `aa` of `aaa` does.
    static func range(ofOccurrence n: Int, of original: String, in text: String) -> NSRange? {
        guard n >= 0 else { return nil }
        let ranges = nonOverlappingRanges(of: original, in: text)
        return ranges.indices.contains(n) ? ranges[n] : nil
    }

    // MARK: live ([String]) corrections

    /// `texts` with the `n`-th (0-based) non-overlapping occurrence of `original`
    /// — counted over the texts joined by single spaces, in document order
    /// (`location(ofOccurrence:of:in:)`) — replaced by `replacement`. Returns
    /// `nil` (leave the source untouched) when `original` is empty, `n` is
    /// negative, there is no `n`-th occurrence, or it crosses a join. Exactly one
    /// occurrence changes, within one text.
    static func replacingOccurrence(
        _ n: Int, of original: String, with replacement: String, in texts: [String]
    ) -> [String]? {
        guard let at = location(ofOccurrence: n, of: original, in: texts) else { return nil }
        var out = texts
        out[at.line] = (texts[at.line] as NSString).replacingCharacters(in: at.range, with: replacement)
        return out
    }

    /// `texts` with every non-overlapping occurrence of `original` replaced.
    /// Empty `original` → unchanged.
    static func replacingAll(
        of original: String, with replacement: String, in texts: [String]
    ) -> [String] {
        guard !original.isEmpty else { return texts }
        return texts.map { $0.replacingOccurrences(of: original, with: replacement) }
    }

    // MARK: saved (markdown) corrections

    /// `markdown` with every occurrence of `original` in the **transcript
    /// paragraph lines** replaced by `replacement`. Frontmatter, card/follow-up
    /// blockquotes (`>` lines), and headings (`# ` lines) are left byte-identical;
    /// of a transcript line only its text (`TranscriptDoc.memberText`) is
    /// touched, so a bullet or stamp is never altered, however the line is
    /// indented (issue #93). The lines are the paragraphs `TranscriptDoc` reads,
    /// so a line has one reading here and on screen. Empty `original` → unchanged.
    static func replacingAllInTranscript(
        of original: String, with replacement: String, inMarkdown markdown: String
    ) -> String {
        guard !original.isEmpty else { return markdown }
        let (prefix, body) = TranscriptDoc.splitFrontmatter(markdown)
        var lines = body.components(separatedBy: "\n")
        for block in TranscriptDoc.timedBlocks(from: body) {
            guard case .paragraph = block.block else { continue }
            let corrected = replacingAll(of: original, with: replacement, in: block.texts)
            for (slot, index) in block.lines.enumerated() where corrected[slot] != block.texts[slot] {
                guard let line = TranscriptDoc.replacingMemberText(of: lines[index], with: corrected[slot])
                else { continue }
                lines[index] = line
            }
        }
        return prefix + lines.joined(separator: "\n")
    }
}
