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
    /// An editorial note the user injected (issue #34): the body text of a
    /// `**NOTE**`-headed blockquote — rendered in distinct (green) chrome.
    case note(String)
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
    /// A display block with the `HH:mm` its first transcript line was spoken —
    /// set for paragraphs with a stamped line, nil for everything else.
    struct TimedBlock: Equatable {
        let block: TranscriptBlock
        let time: String?
    }

    /// `body` must already have frontmatter stripped
    /// (`SessionArchive.strippingFrontmatter`).
    static func blocks(from body: String) -> [TranscriptBlock] {
        timedBlocks(from: body).map(\.block)
    }

    /// `blocks(from:)`, keeping each paragraph's start time for display.
    static func timedBlocks(from body: String) -> [TimedBlock] {
        var blocks: [TimedBlock] = []
        var para: [String] = []
        var paraTime: String?
        var prevSecs: Int?
        var quote: [String] = []

        func flushPara() {
            if !para.isEmpty {
                blocks.append(TimedBlock(block: .paragraph(para.joined(separator: " ")), time: paraTime))
                para = []
            }
            paraTime = nil
            prevSecs = nil
        }
        func flushQuote() {
            if !quote.isEmpty {
                let inner = quote.joined(separator: "\n")
                if let noteBody = noteBody(from: inner) {
                    blocks.append(TimedBlock(block: .note(noteBody), time: nil))
                } else {
                    blocks.append(TimedBlock(block: .card(inner), time: nil))
                }
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
                blocks.append(TimedBlock(block: .heading(String(line.dropFirst(2))), time: nil))
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
                if let secs {
                    prevSecs = secs
                    if paraTime == nil { paraTime = String(format: "%02d:%02d", secs / 3600, secs % 3600 / 60) }
                }
                continue
            }
            // Any other prose line folds into the current paragraph.
            para.append(line)
        }
        flushPara()
        flushQuote()
        return blocks
    }

    /// The body of an editorial-note blockquote, or nil when the inner markdown
    /// isn't one (issue #34). A note is a `**NOTE**` header followed by a blank
    /// line and the note text; the body is everything after that header.
    private static func noteBody(from inner: String) -> String? {
        var lines = inner.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "**NOTE**" else { return nil }
        lines.removeFirst()
        // Drop the single blank separator line the writer emits after the header.
        if lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        return lines.joined(separator: "\n")
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
