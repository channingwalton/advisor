import Foundation

/// Renders a session as markdown that mirrors the window: the conversation with
/// answer/context/fact-check cards embedded inline as "chat" blocks at their
/// place in the stream. The single session format — used both for the auto-saved
/// note (`SessionWriter.write`) and the Export/share action.
enum SessionMarkdown {
    /// Utterances and finished cards are merged chronologically
    /// (a card sorts after an utterance at equal time, so it lands beneath its
    /// triggering line — the same ordering the live feed uses). Only `done`/
    /// `failed` cards are included; in-flight cards are skipped.
    static func inline(
        utterances: [Utterance], cards: [Card], started: Date?, ended: Date?,
        context: String = ""
    ) -> String {
        let iso = ISO8601DateFormatter()
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"

        struct Entry {
            let time: Date
            let isUtterance: Bool
            let text: String
        }

        var entries: [Entry] = utterances.map {
            Entry(time: $0.time, isUtterance: true, text: "- \(time.string(from: $0.time)) \($0.text)")
        }
        entries += cards
            .filter { $0.state == "done" || $0.state == "failed" }
            .map { Entry(time: $0.created, isUtterance: false, text: cardBlock($0)) }
        // Stable: at equal times an utterance precedes a card, so an anchored
        // card renders directly under its line.
        entries.sort { a, b in
            a.time != b.time ? a.time < b.time : (a.isUtterance && !b.isUtterance)
        }

        var md = "---\n"
        if let started { md += "started: \(iso.string(from: started))\n" }
        if let ended { md += "ended: \(iso.string(from: ended))\n" }
        // The session context/prompt, collapsed to one line so it stays a simple
        // frontmatter scalar — used as the session's title in the browser.
        let ctx = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ctx.isEmpty {
            md += "context: \(ctx.replacingOccurrences(of: "\n", with: " "))\n"
        }
        md += "---\n\n# Transcript\n\n"
        md += entries.map(\.text).joined(separator: "\n\n")
        return md + "\n"
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

    /// The pill label shown in the window header — kind, or the verdict for a
    /// resolved fact-check.
    static func label(for card: Card) -> String {
        switch card.kind {
        case "context": return "CONTEXT"
        case "factcheck":
            switch card.verdict {
            case .verified: return "VERIFIED"
            case .needsContext: return "NEEDS CONTEXT"
            case .misleading: return "MISLEADING"
            case nil: return "FACT-CHECK"
            }
        default: return "ANSWER"
        }
    }

    /// A card as a blockquote "chat" block: bold `LABEL · Title` header, the
    /// body markdown, then a footer line (grounding/trigger quote + sources).
    /// Every line is `>`-prefixed so multi-paragraph bodies stay in the quote.
    private static func cardBlock(_ card: Card) -> String {
        var lines = ["**\(label(for: card)) · \(card.title)**"]

        let body = card.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty && body != "…" {
            lines.append("")
            lines += body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }

        let isAnswer = card.kind == "answer" || card.kind == "query"
        var footer = isAnswer ? "Grounded in the live conversation" : ""
        if footer.isEmpty, let quote = card.triggerQuote, !quote.isEmpty {
            footer = "↳ \(quote)"
        }
        footer = footer.isEmpty ? "" : "_\(footer)_"
        let sources = card.sources.map { "[\($0.label)](\($0.url))" }.joined(separator: " · ")
        if !sources.isEmpty { footer = footer.isEmpty ? sources : footer + " · " + sources }
        if !footer.isEmpty {
            lines.append("")
            lines.append(footer)
        }

        return lines.map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")
    }
}
