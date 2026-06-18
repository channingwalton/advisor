import Foundation

/// One renderable block of a saved transcript, reconstructed for display so a
/// past session reads like the live window rather than a timestamped list.
/// Not `Identifiable` — block text can repeat across a transcript, so callers
/// key on position (the list is static, rebuilt wholesale on reload).
enum TranscriptBlock: Equatable {
    /// A run of consecutive transcript lines joined into flowing prose
    /// (timestamps dropped), the way the live feed collapses utterances.
    case paragraph(String)
    /// An inline card / follow-up, as the inner markdown of its blockquote
    /// (header, body, footer) — rendered in card chrome.
    case card(String)
    /// A section heading kept from the note (e.g. "Follow-ups").
    case heading(String)
}

/// Parses a saved session note (the format `SessionMarkdown.inline` writes) back
/// into display blocks — the inverse of the writer. Transcript bullet lines join
/// into paragraphs (a new paragraph when the gap to the previous line exceeds 2s,
/// matching the live feed), blockquotes become cards, and `#` lines headings.
/// Blank lines do not break a paragraph: `inline` separates every entry with a
/// blank line, so consecutive utterances are always blank-line-separated — only
/// the 2s gap or an interrupting card/heading starts a new paragraph.
enum TranscriptDoc {
    /// `body` must already have frontmatter stripped
    /// (`SessionArchive.strippingFrontmatter`).
    static func blocks(from body: String) -> [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        var para: [String] = []
        var prevSecs: Int?
        var quote: [String] = []

        func flushPara() {
            if !para.isEmpty {
                blocks.append(.paragraph(para.joined(separator: " ")))
                para = []
            }
            prevSecs = nil
        }
        func flushQuote() {
            if !quote.isEmpty {
                blocks.append(.card(quote.joined(separator: "\n")))
                quote = []
            }
        }

        for raw in body.components(separatedBy: "\n") {
            if raw.hasPrefix(">") {
                flushPara()
                var inner = String(raw.dropFirst())
                if inner.hasPrefix(" ") { inner.removeFirst() }
                quote.append(inner)
                continue
            }
            flushQuote()

            let line = raw.trimmingCharacters(in: .whitespaces)
            // A blank line ends any open card (handled by flushQuote above) but
            // must not split a paragraph — entries are always blank-separated.
            if line.isEmpty { continue }
            if line.hasPrefix("# ") {
                flushPara()
                blocks.append(.heading(String(line.dropFirst(2))))
                continue
            }
            if line.hasPrefix("- ") {
                let (secs, text) = splitTimestamp(String(line.dropFirst(2)))
                if let prev = prevSecs, let s = secs {
                    // Stamps are HH:mm:ss only, so a session crossing midnight
                    // wraps to a smaller value — add a day before comparing.
                    var delta = s - prev
                    if delta < 0 { delta += 86_400 }
                    if delta > 2 { flushPara() }
                }
                if !text.isEmpty { para.append(text) }
                if let secs { prevSecs = secs }
                continue
            }
            // Any other prose line folds into the current paragraph.
            para.append(line)
        }
        flushPara()
        flushQuote()
        return blocks
    }

    /// Splits a leading `HH:MM:SS ` stamp off a transcript line, returning the
    /// stamp in seconds-of-day and the remaining text. No stamp → (nil, line).
    private static func splitTimestamp(_ s: String) -> (Int?, String) {
        let parts = s.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let stamp = parts.first, stamp.count == 8 else { return (nil, s) }
        let hms = stamp.split(separator: ":")
        guard hms.count == 3, let h = Int(hms[0]), let m = Int(hms[1]), let sec = Int(hms[2])
        else { return (nil, s) }
        let rest = parts.count > 1 ? String(parts[1]) : ""
        return (h * 3600 + m * 60 + sec, rest)
    }
}
