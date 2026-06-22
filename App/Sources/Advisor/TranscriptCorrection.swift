import Foundation

/// Pure text-correction primitives shared by the live feed (in-memory
/// `Utterance`s) and the saved-session browser (markdown file). Everything here
/// operates on plain strings so it is unit-testable without the UI.
///
/// Matching is literal and case-sensitive: `original` is the exact highlighted
/// span. Occurrence counting is non-overlapping, left-to-right, and UTF-16-based
/// so it lines up with the selection offsets `NSTextView` reports.
///
/// Limitation: a selection that straddles a paragraph join boundary (a phrase
/// split across two utterances / two transcript lines by the 2s-gap rule) is out
/// of scope — single-occurrence correction counts within a line/utterance, so a
/// straddling phrase simply won't be found. Whole-session replace is unaffected.
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
        let (prefix, body) = splitBody(markdown)
        let lines = body.components(separatedBy: "\n").map { line -> String in
            guard isParagraphMemberLine(line), let (linePrefix, text) = splitMemberLine(line)
            else { return line }
            return linePrefix + text.replacingOccurrences(of: original, with: replacement)
        }
        return prefix + lines.joined(separator: "\n")
    }

    /// `markdown` with the `n`-th occurrence of `original` within the transcript
    /// paragraph at `paragraphIndex` (0-based, counting only paragraph blocks, the
    /// same way `TranscriptDoc` groups them) replaced by `replacement`. Returns the
    /// input unchanged when the paragraph or the `n`-th occurrence does not exist.
    static func replacingOccurrence(
        _ n: Int, of original: String, with replacement: String,
        inParagraph paragraphIndex: Int, ofMarkdown markdown: String
    ) -> String {
        guard !original.isEmpty, n >= 0, paragraphIndex >= 0 else { return markdown }
        let (prefix, body) = splitBody(markdown)
        var lines = body.components(separatedBy: "\n")
        let paragraphs = paragraphMemberIndices(in: lines)
        guard paragraphIndex < paragraphs.count else { return markdown }

        let memberIndices = paragraphs[paragraphIndex]
        // The text portions of this paragraph's member lines, in document order.
        let texts = memberIndices.map { splitMemberLine(lines[$0])?.text ?? lines[$0] }
        guard let corrected = replacingOccurrence(n, of: original, with: replacement, in: texts)
        else { return markdown }

        for (slot, lineIndex) in memberIndices.enumerated() where corrected[slot] != texts[slot] {
            let linePrefix = splitMemberLine(lines[lineIndex])?.prefix ?? ""
            lines[lineIndex] = linePrefix + corrected[slot]
        }
        return prefix + lines.joined(separator: "\n")
    }

    // MARK: markdown helpers

    /// Splits leading YAML frontmatter (`---` … `---`, plus the blank lines after
    /// it) off `markdown`, returning (prefix-to-preserve-verbatim, body). The body
    /// is what `TranscriptDoc` parses; the prefix is re-prepended unchanged so a
    /// correction never disturbs frontmatter. No frontmatter → ("", markdown).
    private static func splitBody(_ markdown: String) -> (prefix: String, body: String) {
        guard markdown.hasPrefix("---\n"),
            let close = markdown.range(
                of: "\n---\n",
                range: markdown.index(markdown.startIndex, offsetBy: 4)..<markdown.endIndex)
        else { return ("", markdown) }
        var bodyStart = close.upperBound
        while bodyStart < markdown.endIndex, markdown[bodyStart] == "\n" {
            bodyStart = markdown.index(after: bodyStart)
        }
        return (String(markdown[..<bodyStart]), String(markdown[bodyStart...]))
    }

    /// True for a line that contributes prose to a transcript paragraph: not a
    /// blockquote (`>`), heading (`#`), or blank line. Mirrors `TranscriptDoc`.
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

    /// Groups `lines` into transcript paragraphs the way `TranscriptDoc` does,
    /// returning each paragraph as the list of its member line indices (in order).
    /// A blockquote or heading flushes the current paragraph; a >2s stamp gap
    /// starts a new one (midnight rollover handled); blank lines don't break.
    private static func paragraphMemberIndices(in lines: [String]) -> [[Int]] {
        var paragraphs: [[Int]] = []
        var current: [Int] = []
        var prevSecs: Int?
        func flush() {
            if !current.isEmpty { paragraphs.append(current); current = [] }
            prevSecs = nil
        }
        for (index, line) in lines.enumerated() {
            if line.hasPrefix(">") { flush(); continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("# ") { flush(); continue }
            // Every remaining line is a paragraph member (non-blank, non-quote,
            // non-heading), so `splitMemberLine` is non-nil here.
            let (prefix, text) = splitMemberLine(line) ?? ("", line)
            let secs = stampSeconds(prefix)
            if let prev = prevSecs, let s = secs {
                var delta = s - prev
                if delta < 0 { delta += 86_400 }
                if delta > 2 { flush() }
            }
            // Mirror TranscriptDoc: an empty-text stamp line updates the gap clock
            // but is not a paragraph member, so paragraph indices stay in lock-step
            // with the displayed blocks.
            if !text.isEmpty { current.append(index) }
            if let secs { prevSecs = secs }
        }
        flush()
        return paragraphs
    }

    /// Seconds-of-day of a `- HH:MM:SS ` member-line prefix, or nil when the
    /// prefix carries no stamp.
    private static func stampSeconds(_ prefix: String) -> Int? {
        guard prefix.hasPrefix("- "), prefix.count >= 10 else { return nil }
        let stampChars = Array(prefix.dropFirst(2).prefix(8))
        guard stampChars.count == 8,
            let h = Int(String(stampChars[0...1])),
            let m = Int(String(stampChars[3...4])),
            let s = Int(String(stampChars[6...7]))
        else { return nil }
        return h * 3600 + m * 60 + s
    }
}
