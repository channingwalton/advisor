import Foundation

/// Pure text-correction primitives shared by the live feed (in-memory
/// `Utterance`s) and the saved-session browser (markdown file). Everything here
/// operates on plain strings so it is unit-testable without the UI.
///
/// Matching is literal and case-sensitive: `original` is the exact highlighted
/// span. Occurrence counting is non-overlapping, left-to-right, and UTF-16-based
/// so it lines up with the selection offsets `NSTextView` reports.
///
/// Limitation: matching is per line/utterance, but a paragraph shows its lines
/// joined by spaces. A selection that straddles a join isn't found, and a
/// straddling match earlier in the paragraph shifts the count the menu took from
/// the joined text, so single-occurrence correction can hit a later match.
/// Whole-session replace skips straddling matches (DESIGN.md, issue #91).
enum TranscriptCorrection {

    // MARK: occurrence counting

    /// 0-based occurrence index of a selection of `original` that starts at UTF-16
    /// offset `location` in `text` — i.e. how many non-overlapping occurrences of
    /// `original` begin strictly before `location`. Empty `original` → 0.
    static func occurrenceIndex(of original: String, before location: Int, in text: String) -> Int {
        guard !original.isEmpty else { return 0 }
        let ns = text as NSString
        var count = 0
        var searchStart = 0
        while searchStart <= ns.length {
            let range = ns.range(
                of: original, options: [],
                range: NSRange(location: searchStart, length: ns.length - searchStart))
            guard range.location != NSNotFound, range.location < location else { break }
            count += 1
            searchStart = range.location + max(range.length, 1)
        }
        return count
    }

    // MARK: live ([String]) corrections

    /// `texts` with the `n`-th (0-based) non-overlapping occurrence of `original`
    /// — counted across the whole sequence in document order — replaced by
    /// `replacement`. Returns `nil` (leave the source untouched) when `original`
    /// is empty, `n` is negative, or there is no `n`-th occurrence. Exactly one
    /// occurrence changes.
    static func replacingOccurrence(
        _ n: Int, of original: String, with replacement: String, in texts: [String]
    ) -> [String]? {
        guard !original.isEmpty, n >= 0 else { return nil }
        var remaining = n
        var out = texts
        for index in texts.indices {
            let ns = texts[index] as NSString
            var searchStart = 0
            while searchStart <= ns.length {
                let range = ns.range(
                    of: original, options: [],
                    range: NSRange(location: searchStart, length: ns.length - searchStart))
                guard range.location != NSNotFound else { break }
                if remaining == 0 {
                    out[index] = ns.replacingCharacters(in: range, with: replacement)
                    return out
                }
                remaining -= 1
                searchStart = range.location + max(range.length, 1)
            }
        }
        return nil
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

    /// `markdown` with every occurrence of `original` in the **transcript body
    /// lines** replaced by `replacement`. Frontmatter, card/follow-up blockquotes
    /// (`>` lines), and headings (`#` lines) are left byte-identical — only the
    /// text portion of `- HH:MM:SS …` utterance lines is touched. Empty `original`
    /// → unchanged.
    static func replacingAllInTranscript(
        of original: String, with replacement: String, inMarkdown markdown: String
    ) -> String {
        guard !original.isEmpty else { return markdown }
        let (prefix, body) = TranscriptDoc.splitFrontmatter(markdown)
        let lines = body.components(separatedBy: "\n").map { line -> String in
            guard isParagraphMemberLine(line), let (linePrefix, text) = splitMemberLine(line)
            else { return line }
            return linePrefix + text.replacingOccurrences(of: original, with: replacement)
        }
        return prefix + lines.joined(separator: "\n")
    }

    // MARK: markdown helpers

    /// True for a line that contributes prose to a transcript paragraph: not a
    /// blockquote (`>`), heading (`#`), or blank line, as `TranscriptDoc` reads
    /// it — though `splitMemberLine` takes an indented bullet as plain prose.
    private static func isParagraphMemberLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !line.hasPrefix(">") && !trimmed.hasPrefix("# ")
    }

    /// Splits a paragraph member line into the prefix to keep verbatim and the
    /// replaceable text. For a `- HH:MM:SS text` line the prefix is the bullet and
    /// stamp (so a correction can never alter a timestamp); a stampless line keeps
    /// only the `- `; any other prose line is entirely text. Returns nil for a
    /// non-member line.
    private static func splitMemberLine(_ line: String) -> (prefix: String, text: String)? {
        guard isParagraphMemberLine(line) else { return nil }
        guard line.hasPrefix("- ") else { return (prefix: "", text: line) }
        let afterBullet = String(line.dropFirst(2))
        let parts = afterBullet.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        if let stamp = parts.first, stamp.count == 8, isStamp(String(stamp)) {
            if parts.count > 1 {
                return (prefix: "- \(stamp) ", text: String(parts[1]))
            }
            return (prefix: "- \(stamp)", text: "")
        }
        return (prefix: "- ", text: afterBullet)
    }

    /// `HH:MM:SS` shape check — eight chars, colons at 2 and 5, digits elsewhere.
    private static func isStamp(_ s: String) -> Bool {
        let chars = Array(s)
        guard chars.count == 8, chars[2] == ":", chars[5] == ":" else { return false }
        for (i, c) in chars.enumerated() where i != 2 && i != 5 {
            guard c.isNumber else { return false }
        }
        return true
    }
}
