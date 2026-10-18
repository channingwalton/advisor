import Foundation

/// One transcript line inside a feed paragraph: a live utterance or a saved
/// note's transcript line. `id` lets an action map back to its source.
struct FeedLine: Equatable {
    let id: String
    let text: String
}

/// A run of consecutive transcript lines rendered as one flowing paragraph.
struct FeedParagraph: Identifiable, Equatable {
    let id: String
    let lines: [FeedLine]
    /// `HH:mm` the first line was spoken, hung in the margin; nil when unknown.
    let time: String?
    var toolTip: String = ""

    /// The lines joined by single spaces, as shown.
    var text: String { lines.map(\.text).joined(separator: " ") }
}

/// A row of the shared feed (`FeedView`) — the same shapes for the live
/// recording and a saved session, so both windows render and act alike.
enum FeedItem: Identifiable {
    /// Consecutive paragraphs between cards, notes or headings.
    case transcript([FeedParagraph])
    case card(Card)
    /// An editorial note (issue #34).
    case note(id: String, text: String)
    /// A section heading kept from a saved note (Summary, Follow-ups).
    case heading(id: String, title: String)

    var id: String {
        switch self {
        case .transcript(let ps): "t-\(ps.first?.id ?? "empty")"
        case .card(let c): "c-\(c.id)"
        case .note(let id, _): "n-\(id)"
        case .heading(let id, _): "h-\(id)"
        }
    }
}

enum Feed {
    /// The live session as feed items, one paragraph per `.transcript`: utterances,
    /// cards and notes merged chronologically. At equal times an utterance sorts
    /// first, then a note anchored to that line, then a card — so the note hugs
    /// its text and the card sits below (issue #34). A new paragraph starts when
    /// the gap to the previous line exceeds 2s, or when a card or note interrupts.
    static func live(utterances: [Utterance], cards: [Card], notes: [EditorialNote]) -> [FeedItem] {
        enum Entry {
            case utterance(Utterance), card(Card), note(EditorialNote)
        }
        func key(_ e: Entry) -> (Date, Int) {
            switch e {
            case .utterance(let u): (u.time, 0)
            case .note(let n): (n.time, 1)
            case .card(let c): (c.created, 2)
            }
        }
        let entries = (utterances.map(Entry.utterance) + notes.map(Entry.note) + cards.map(Entry.card))
            .sorted { key($0) < key($1) }

        var items: [FeedItem] = []
        var buf: [Utterance] = []
        func flush() {
            guard let first = buf.first else { return }
            items.append(.transcript([FeedParagraph(
                id: first.id.uuidString,
                lines: buf.map { FeedLine(id: $0.id.uuidString, text: $0.text) },
                time: marginTime.string(from: first.time),
                toolTip: first.time.formatted(date: .omitted, time: .standard))]))
            buf.removeAll()
        }
        for entry in entries {
            switch entry {
            case .utterance(let u):
                if let last = buf.last, u.time.timeIntervalSince(last.time) > 2 { flush() }
                buf.append(u)
            case .card(let c):
                flush()
                items.append(.card(c))
            case .note(let n):
                flush()
                items.append(.note(id: n.id.uuidString, text: n.text))
            }
        }
        flush()
        return items
    }

    /// A saved session's display blocks as feed items, one paragraph per
    /// `.transcript`. Paragraph ids are block offsets (corrections key on them);
    /// cards and notes take their `savedIds`. `times` and `lines` parallel
    /// `blocks` (`SessionDetail.blockTimes`, `blockLines`): a paragraph's feed
    /// lines are its transcript lines, which it shows joined by single spaces, so
    /// the correction menu can tell a selection across a join (issue #92); with
    /// no lines for it, the paragraph is one line. All of a paragraph's lines
    /// share its id. The `# Transcript` heading is dropped — the detail labels
    /// that section itself.
    static func saved(blocks: [TranscriptBlock], times: [String?], lines: [[String]] = []) -> [FeedItem] {
        let ids = savedIds(blocks)
        return blocks.enumerated().compactMap { offset, block in
            switch block {
            case .paragraph(let text):
                let time = times.indices.contains(offset) ? times[offset] : nil
                let texts = lines.indices.contains(offset) && !lines[offset].isEmpty ? lines[offset] : [text]
                return .transcript([FeedParagraph(
                    id: "\(offset)", lines: texts.map { FeedLine(id: "\(offset)", text: $0) }, time: time)])
            case .card(let markdown):
                return .card(SavedCard.card(from: markdown, id: ids[offset] ?? "\(offset)"))
            case .note(let text):
                return .note(id: ids[offset] ?? "\(offset)", text: text)
            case .heading(let title):
                return title == "Transcript" ? nil : .heading(id: "\(offset)", title: title)
            }
        }
    }

    /// Ids for a saved note's cards and notes, parallel to `blocks` (nil for
    /// paragraphs and headings): a digest of the block's markdown plus how many
    /// identical blocks precede it. They follow the content, so a card keeps its
    /// id — and its collapse state — when other blocks are added or removed; an
    /// edit maps an id back to its block offset with `firstIndex(of:)`.
    static func savedIds(_ blocks: [TranscriptBlock]) -> [String?] {
        var seen: [String: Int] = [:]
        return blocks.map { block in
            let base: String
            switch block {
            case .card(let markdown): base = "s\(digest(markdown))"
            case .note(let text): base = "n\(digest(text))"
            case .paragraph, .heading: return nil
            }
            let n = seen[base, default: 0]
            seen[base] = n + 1
            return "\(base)-\(n)"
        }
    }

    /// FNV-1a: a short, deterministic digest (Swift's `hashValue` is seeded per run).
    private static func digest(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100_0000_01b3
        }
        return String(h, radix: 16)
    }

    /// `items` for display: adjacent transcript rows merge into one run, so
    /// transcript and cards read as distinct blocks. Hiding the transcript drops
    /// paragraphs and headings but keeps cards and notes — notes are the user's
    /// own signal, not transcript chatter.
    static func grouped(_ items: [FeedItem], hideTranscript: Bool) -> [FeedItem] {
        var out: [FeedItem] = []
        for item in items {
            switch item {
            case .transcript where hideTranscript, .heading where hideTranscript:
                continue
            case .transcript(let ps):
                if case .transcript(let run) = out.last {
                    out[out.count - 1] = .transcript(run + ps)
                } else {
                    out.append(item)
                }
            default:
                out.append(item)
            }
        }
        return out
    }

    /// `items` (one paragraph per transcript row, as `saved` returns them) with
    /// in-flight `cards` shown under the paragraph each was asked about — after
    /// the cards and notes already there, where the finished card will be saved.
    /// A card whose paragraph has gone goes at the end.
    static func inserting(_ cards: [(afterParagraph: String, card: Card)], into items: [FeedItem]) -> [FeedItem] {
        guard !cards.isEmpty else { return items }
        var out: [FeedItem] = []
        var waiting: [Card] = []
        var placed = Set<String>()
        for item in items {
            switch item {
            case .transcript, .heading:
                out += waiting.map(FeedItem.card)
                waiting = []
            case .card, .note:
                break
            }
            out.append(item)
            if case .transcript(let ps) = item, let id = ps.last?.id {
                for entry in cards where entry.afterParagraph == id {
                    waiting.append(entry.card)
                    placed.insert(entry.card.id)
                }
            }
        }
        out += waiting.map(FeedItem.card)
        out += cards.filter { !placed.contains($0.card.id) }.map { FeedItem.card($0.card) }
        return out
    }

    /// `items` with each card's expansion overridden where `overrides` (keyed by
    /// card id) has it; other cards keep their default.
    static func applyingExpansion(_ overrides: [String: Bool], to items: [FeedItem]) -> [FeedItem] {
        mapCards(items) { card in
            if let expanded = overrides[card.id] { card.isExpanded = expanded }
        }
    }

    /// `items` with `update` applied to every card.
    static func mapCards(_ items: [FeedItem], _ update: (inout Card) -> Void) -> [FeedItem] {
        items.map { item in
            guard case .card(var card) = item else { return item }
            update(&card)
            return .card(card)
        }
    }

    private static let marginTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()
}

/// Reads a saved card block (the inner markdown `SessionMarkdown` writes, with
/// the `>` markers stripped by `TranscriptDoc`) back into the `Card` the live
/// feed uses, so a saved session renders through the same card view.
enum SavedCard {
    /// `**LABEL · Title**` (or a label-only `**SUMMARY**`) header, the body,
    /// then an optional one-line footer in the writer's own forms: an italic note
    /// (`_↳ quote_`, `_Grounded in the live conversation_` or `…saved transcript_`,
    /// a follow-up's
    /// `_Asked …_`), optionally followed by ` · `-separated source links. A
    /// links-only last line stays in the body — it can't be told apart from the
    /// body's own citations. A block without a known header isn't one Advisor
    /// wrote, so it has no kind and no footer.
    static func card(from markdown: String, id: String) -> Card {
        var lines = markdown.components(separatedBy: "\n")
        var label = ""
        var kind = ""
        var verdict: Verdict?
        var title = ""
        if let header = lines.first?.trimmingCharacters(in: .whitespaces),
            header.count > 4, header.hasPrefix("**"), header.hasSuffix("**")
        {
            let inner = String(header.dropFirst(2).dropLast(2))
            let sep = inner.range(of: " · ")
            let headerLabel = sep.map { String(inner[..<$0.lowerBound]) } ?? inner
            // An unrecognised bold first line is the body's own text.
            if let known = kindAndVerdict(headerLabel) {
                (label, kind, verdict) = (headerLabel, known.kind, known.verdict)
                title = sep.map { String(inner[$0.upperBound...]) } ?? ""
                lines.removeFirst()
            }
        }
        trimBlank(&lines)

        var quote: String?
        var footnote: String?
        var sources: [Citation] = []
        // A summary never has a footer.
        if !kind.isEmpty, kind != "summary", let last = lines.last,
            let footer = parseFooter(last, followUp: label == "Q")
        {
            lines.removeLast()
            trimBlank(&lines)
            sources = footer.sources
            if footer.note.hasPrefix("↳ ") {
                quote = String(footer.note.dropFirst(2))
            } else if footer.note != groundedNote {
                footnote = footer.note
            }
        }

        return Card(
            id: id, created: .distantPast, kind: kind,
            title: kind == "summary" && title.isEmpty ? "Summary" : title,
            body: lines.joined(separator: "\n"), state: "done",
            triggerQuote: quote, sources: sources, verdict: verdict, footnote: footnote,
            // Fact-checks start collapsed, as they do live.
            isExpanded: kind != "factcheck")
    }

    /// The footer the writer gives live answer cards; the card view shows it itself.
    static let groundedNote = "Grounded in the live conversation"
    /// The footer of an answer researched from a saved transcript (Sessions),
    /// kept as the card's `footnote` — it wasn't grounded in a live conversation.
    static let savedGroundedNote = "Grounded in the saved transcript"

    private static func kindAndVerdict(_ label: String) -> (kind: String, verdict: Verdict?)? {
        switch label {
        case "ANSWER": ("answer", nil)
        case "CONTEXT": ("context", nil)
        case "SUMMARY": ("summary", nil)
        case "Q": ("question", nil)
        case "VERIFIED": ("factcheck", .verified)
        case "NEEDS CONTEXT": ("factcheck", .needsContext)
        case "MISLEADING": ("factcheck", .misleading)
        case "FACT-CHECK": ("factcheck", nil)
        default: nil
        }
    }

    /// The footer line's italic note and source links, or nil when `line` isn't
    /// one of the writer's footers (so it stays part of the body).
    private static func parseFooter(_ line: String, followUp: Bool) -> (note: String, sources: [Citation])? {
        let line = line.trimmingCharacters(in: .whitespaces)
        func isNote(_ note: Substring) -> Bool {
            note == groundedNote || note == savedGroundedNote || note.hasPrefix("↳ ")
                || (followUp && note.hasPrefix("Asked "))
        }
        guard line.hasPrefix("_") else { return nil }
        let afterOpen = line.index(after: line.startIndex)
        // `_note_` alone, or `_note_ · [label](url) · …`.
        if line.count > 2, line.hasSuffix("_") {
            let note = line[afterOpen..<line.index(before: line.endIndex)]
            if isNote(note) { return (String(note), []) }
        }
        var from = afterOpen
        while let sep = line.range(of: "_ · [", range: from..<line.endIndex) {
            let note = line[afterOpen..<sep.lowerBound]
            if isNote(note), let sources = parseSources(line[line.index(sep.upperBound, offsetBy: -1)...]) {
                return (String(note), sources)
            }
            from = sep.upperBound
        }
        return nil
    }

    /// `[label](url)` links joined by ` · `, or nil if `s` is anything else.
    /// Labels may themselves contain ` · ` (page titles do) and URLs `)`.
    private static func parseSources(_ s: Substring) -> [Citation]? {
        let ns = String(s) as NSString
        var location = 0
        var sources: [Citation] = []
        while location < ns.length {
            let range = NSRange(location: location, length: ns.length - location)
            guard let m = link.firstMatch(in: ns as String, options: .anchored, range: range) else { return nil }
            sources.append(Citation(label: ns.substring(with: m.range(at: 1)), url: ns.substring(with: m.range(at: 2))))
            location = m.range.location + m.range.length
        }
        return sources.isEmpty ? nil : sources
    }

    private static let link = try! NSRegularExpression(pattern: #"\[(.+?)\]\((\S+?)\)(?: · (?=\[)|$)"#)

    private static func trimBlank(_ lines: inout [String]) {
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
    }
}
