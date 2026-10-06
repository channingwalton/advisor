import Foundation

/// A card Advisor surfaced during a session, as shown in the "Cards surfaced"
/// list — reconstructed from the saved note's inline card blocks.
struct SurfacedCard: Equatable {
    let label: String // ANSWER, CONTEXT, VERIFIED, NEEDS CONTEXT, MISLEADING, FACT-CHECK
    let title: String
    let snippet: String
}

/// A question the user asked about a session (the `# Follow-ups` blocks), shown
/// in the "You asked" list.
struct AskedQuestion: Equatable {
    let question: String
    let askedAt: String // "HH:MM", or "" if absent
}

/// A saved session parsed into everything the Sessions browser shows: its title
/// and gist, timing, the cards it surfaced, the questions asked of it, and the
/// full transcript blocks. Built from the note `SessionMarkdown.inline` writes —
/// the data the "Layout + real data" Sessions view renders (no AI-derived
/// category/topics/summary/people).
struct SessionDetail: Equatable {
    let title: String
    /// The user-given session name (`name:` frontmatter), or "" if unnamed. The
    /// rename field pre-fills from this; `title` uses it when present.
    let name: String
    /// The research context (`context:` frontmatter), or "". Kept distinct from
    /// `title` so search still matches it even when a `name` overrides the title.
    let context: String
    /// The session's tag names (`tags:` frontmatter, comma-separated), in order,
    /// or empty. Colours are resolved against the tag library at render time, so
    /// these are just the names (issue #15).
    let tags: [String]
    let gist: String
    let started: Date?
    let ended: Date?
    let cards: [SurfacedCard]
    let questions: [AskedQuestion]
    let blocks: [TranscriptBlock]
    /// `HH:mm` each block's first transcript line was spoken, parallel to
    /// `blocks` (nil for cards, notes, headings and unstamped prose).
    let blockTimes: [String?]

    /// Session length in whole minutes, when both ends are known.
    var durationMinutes: Int? {
        guard let started, let ended else { return nil }
        return max(0, Int(ended.timeIntervalSince(started) / 60))
    }

    /// "1 card", "9 cards".
    static func cardCount(_ n: Int) -> String { n == 1 ? "1 card" : "\(n) cards" }

    /// Parse a note. `fallbackTitle` (the formatted date) is used when the note
    /// carries no `context` to title it.
    static func parse(contents: String, fallbackTitle: String) -> SessionDetail {
        let fm = SessionArchive.frontmatter(contents)
        let iso = ISO8601DateFormatter()
        let name = fm["name"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let context = fm["context"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let tags = SessionArchive.parseTags(fm["tags"] ?? "")
        let timed = TranscriptDoc.timedBlocks(from: SessionArchive.strippingFrontmatter(contents))
        let blocks = timed.map(\.block)

        var cards: [SurfacedCard] = []
        var questions: [AskedQuestion] = []
        for block in blocks {
            guard case .card(let md) = block else { continue }
            let (label, title, snippet) = parseCard(md)
            if label == "Q" {
                questions.append(AskedQuestion(question: title, askedAt: askedTime(md)))
            } else {
                cards.append(SurfacedCard(label: label, title: title, snippet: snippet))
            }
        }

        let firstParagraph = blocks.lazy.compactMap { block -> String? in
            if case .paragraph(let t) = block { t } else { nil }
        }.first ?? ""

        // A user-given name wins; otherwise the research context; otherwise date.
        let title = !name.isEmpty ? name : (context.isEmpty ? fallbackTitle : context)
        return SessionDetail(
            title: title,
            name: name,
            context: context,
            tags: tags,
            gist: truncated(firstParagraph, max: 90),
            started: fm["started"].flatMap(iso.date(from:)),
            ended: fm["ended"].flatMap(iso.date(from:)),
            cards: cards,
            questions: questions,
            blocks: blocks,
            blockTimes: timed.map(\.time))
    }

    /// Splits a card's inner markdown into (label, title, snippet). The header is
    /// `**LABEL · Title**`; the snippet is the first body line that is neither the
    /// header nor the italic footer.
    private static func parseCard(_ markdown: String) -> (String, String, String) {
        let lines = markdown.components(separatedBy: "\n")
        let header = lines.first ?? ""
        var inner = header
        if inner.hasPrefix("**") { inner.removeFirst(2) }
        if inner.hasSuffix("**") { inner.removeLast(2) }
        let label: String
        let title: String
        if let sep = inner.range(of: " · ") {
            label = String(inner[..<sep.lowerBound])
            title = String(inner[sep.upperBound...])
        } else {
            label = ""
            title = inner
        }
        let snippet = lines.dropFirst().first { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("_")
        }
        return (label, title, truncated(snippet ?? "", max: 80))
    }

    /// Pulls `HH:MM` out of a follow-up's `_Asked HH:MM:SS · …_` footer. Anchored
    /// to the italic footer line (`_Asked …_`, optionally blockquote-prefixed),
    /// not the first "Asked " anywhere — an answer body mentioning "Asked …" must
    /// not be read as the timestamp (issue #65).
    private static func askedTime(_ markdown: String) -> String {
        for line in markdown.components(separatedBy: "\n") {
            var t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(">") { t = t.dropFirst().trimmingCharacters(in: .whitespaces) }
            guard t.hasPrefix("_Asked ") else { continue }
            return String(t.dropFirst("_Asked ".count).prefix(5)) // HH:MM
        }
        return ""
    }

    private static func truncated(_ s: String, max: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > max ? String(t.prefix(max)).trimmingCharacters(in: .whitespaces) + "…" : t
    }
}
