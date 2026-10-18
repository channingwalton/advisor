import Foundation

/// Renders a session as markdown that mirrors the window: the conversation with
/// answer/context/fact-check cards embedded inline as "chat" blocks at their
/// place in the stream. The single session format — used both for the auto-saved
/// note (`SessionWriter.write`) and the Export/share action.
enum SessionMarkdown {
    /// Utterances and finished cards are merged chronologically
    /// (a card sorts after an utterance at equal time, so it lands beneath its
    /// triggering line — the same ordering the live feed uses). Each card goes in
    /// as `Card.persisted`: finished cards as they stand, a card mid-follow-up or
    /// cancelled as its last completed answer, and a card that never completed
    /// not at all.
    static func inline(
        utterances: [Utterance], cards: [Card], notes: [EditorialNote] = [],
        started: Date?, ended: Date?,
        context: String = "", name: String = "", tags: [String] = []
    ) -> String {
        let iso = ISO8601DateFormatter()
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"

        struct Entry {
            let time: Date
            // Tie-break rank at equal times: utterance (0) first, then the user's
            // own note (1) hugging its line, then any card (2) below it (issue #34).
            let rank: Int
            let text: String
        }

        var entries: [Entry] = utterances.map {
            Entry(time: $0.time, rank: 0, text: "- \(time.string(from: $0.time)) \($0.text)")
        }
        entries += cards
            // The summary card isn't an inline transcript entry — it renders in
            // its own `# Summary` section (below), so the note holds one summary.
            .filter { $0.kind != "summary" }
            .compactMap(\.persisted)
            .map { Entry(time: $0.created, rank: 2, text: cardBlock($0)) }
        // Editorial notes the user injected (issue #34) sit inline at their anchor
        // time, in their own `**NOTE**` blockquote.
        entries += notes.map {
            Entry(time: $0.time, rank: 1, text: noteBlock($0.text))
        }
        // Stable: at equal times an utterance precedes its note, which precedes a
        // card, so each renders directly under the line it belongs to.
        entries.sort { a, b in
            a.time != b.time ? a.time < b.time : a.rank < b.rank
        }

        var md = "---\n"
        // An optional user-given label, taking precedence over `context` as the
        // session's title in the browser. Collapsed to one line like `context`.
        let nm = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nm.isEmpty {
            md += "name: \(nm.replacingOccurrences(of: "\n", with: " "))\n"
        }
        if let started { md += "started: \(iso.string(from: started))\n" }
        if let ended { md += "ended: \(iso.string(from: ended))\n" }
        // The session context/prompt, collapsed to one line so it stays a simple
        // frontmatter scalar — used as the session's title in the browser.
        let ctx = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ctx.isEmpty {
            md += "context: \(ctx.replacingOccurrences(of: "\n", with: " "))\n"
        }
        // The session's tags, comma-separated on one line — `SessionArchive`
        // owns the canonical formatting so the live note and a browser edit
        // produce identical lines.
        let tagLine = SessionArchive.tagsLine(tags)
        if !tagLine.isEmpty { md += "tags: \(tagLine)\n" }
        md += "---\n\n"
        // A summary, when one has been produced, leads the note in its own
        // section — the same `# Summary` block a saved-note upsert writes, so the
        // two surfaces stay byte-compatible and "update existing" works across them.
        let summary = summaryText(in: cards)
        if !summary.isEmpty {
            md += "# Summary\n\n" + summaryBlock(summary) + "\n\n"
        }
        md += "# Transcript\n\n"
        md += entries.map(\.text).joined(separator: "\n\n")
        return md + "\n"
    }

    /// The session's summary body, from its single summary card (empty when
    /// none). While a re-summarise runs, or after one fails, that is the last
    /// completed summary; a first summarise that hasn't finished yields none.
    static func summaryText(in cards: [Card]) -> String {
        guard let card = cards.first(where: { $0.kind == "summary" }) else { return "" }
        let text = card.state == "done" ? card.body : card.settledBody ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The summary as a `>`-quoted card block (`**SUMMARY**` + body),
    /// matching the inline card style so a saved summary renders in card chrome.
    /// The single block written into a note's `# Summary` section by both the live
    /// writer (via `inline`) and a saved-note `upsertSummary`.
    static func summaryBlock(_ text: String) -> String {
        // Header is just the label — unlike other cards there's no separate title
        // to add (it would read "SUMMARY · Summary").
        var lines = ["**SUMMARY**"]
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            lines.append("")
            lines += body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }
        return lines.map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")
    }

    /// A follow-up Q&A (asked from the history browser) as a blockquote "chat"
    /// block, matching the inline card style: a bold `Q · question` header, the
    /// answer markdown, then an `_Asked …_` footer. Every line is `>`-prefixed so
    /// a multi-paragraph answer stays in the quote. Appended to the saved note.
    static func followUpBlock(question: String, answer: String, asked: Date) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.calendar = Calendar(identifier: .gregorian)
        stamp.dateFormat = "HH:mm:ss · yyyy-MM-dd"

        var lines = ["**Q · \(question)**"]
        let body = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            lines.append("")
            lines += body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }
        lines.append("")
        lines.append("_Asked \(stamp.string(from: asked))_")
        return lines.map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")
    }

    /// A card's body after a follow-up: the body so far, a rule, the user's
    /// question, then the answer — the turn format the sidecar streams for a live
    /// `card_reply`, so live and saved threads read alike.
    static func replyBody(base: String, question: String, answer: String) -> String {
        "\(base)\n\n---\n\n**You:** \(question)\n\n\(answer)"
    }

    /// An editorial note as a `**NOTE**`-headed blockquote (issue #34) — the same
    /// "chat" block style as cards, so a saved note renders in card chrome, but
    /// with a `NOTE` header `TranscriptDoc` parses back to a `.note` block.
    static func noteBlock(_ text: String) -> String {
        var lines = ["**NOTE**"]
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            lines.append("")
            lines += body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }
        return lines.map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")
    }

    /// The header label — the card's kind, as `SavedCard.card(from:id:)` reads
    /// it back. (Saved follow-ups' `Q` header is written elsewhere.)
    static func label(for card: Card) -> String {
        switch card.kind {
        case "context": return "CONTEXT"
        case "summary": return "SUMMARY"
        case "factcheck": return "FACT-CHECK"
        default: return "ANSWER"
        }
    }

    /// A card as a blockquote "chat" block: bold `LABEL · Title` header, the
    /// body markdown, then a footer line (grounding note or trigger quote).
    /// Every line is `>`-prefixed so multi-paragraph bodies stay in the quote.
    static func cardBlock(_ card: Card) -> String {
        var lines = ["**\(label(for: card)) · \(card.title)**"]

        let body = card.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty && body != "…" {
            lines.append("")
            lines += body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }

        let isAnswer = card.kind == "answer" || card.kind == "query"
        var footer = card.footnote ?? (isAnswer ? SavedCard.groundedNote : "")
        if footer.isEmpty, let quote = card.triggerQuote, !quote.isEmpty {
            footer = "↳ \(quote)"
        }
        if !footer.isEmpty {
            lines.append("")
            lines.append("_\(footer)_")
        }

        return lines.map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")
    }
}
