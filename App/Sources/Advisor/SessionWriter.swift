import Foundation

/// Writes each session to an app-managed markdown file (transcripts + cards).
/// The Obsidian vault is never written.
@MainActor
final class SessionWriter {
    let sessionsDirectory: URL
    private let store: TranscriptStore
    private var fileURL: URL?
    private var started: Date?
    private var ended: Date?
    private var pendingWrite: DispatchWorkItem?

    init(store: TranscriptStore) {
        self.store = store
        sessionsDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Advisor/sessions", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: sessionsDirectory, withIntermediateDirectories: true)
    }

    func start() {
        started = Date()
        ended = nil
        let fmt = DateFormatter()
        // Pin the calendar/locale so the filename is always Gregorian yyyy-MM-dd
        // regardless of the user's system calendar (e.g. Japanese/Buddhist).
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        fileURL = sessionsDirectory.appendingPathComponent("\(fmt.string(from: started!)).md")
        write()
    }

    func end() {
        ended = Date()
        write()
        // fileURL stays set: cards finishing after stop still land in the file.
    }

    /// Debounced rewrite; call whenever utterances or cards change.
    func noteChanged() {
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.write() }
        pendingWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func write() {
        guard let fileURL, let started else { return }
        let iso = ISO8601DateFormatter()
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"

        // Cards anchored to a known transcript line become footnotes on that
        // line (bidirectional link in Obsidian/GitHub); the rest go in a flat
        // "Other cards" section.
        let doneCards = store.cards.filter { $0.state == "done" || $0.state == "failed" }
        var refsByUtterance: [UUID: [String]] = [:]
        var footnotes: [(label: String, card: Card)] = []
        var orphans: [Card] = []
        for card in doneCards {
            if let tid = card.triggerId,
                let u = store.utterances.first(where: { $0.id.uuidString == tid }) {
                let label = "card-\(footnotes.count + 1)"
                refsByUtterance[u.id, default: []].append(label)
                footnotes.append((label, card))
            } else {
                orphans.append(card)
            }
        }

        var md = "---\n"
        md += "started: \(iso.string(from: started))\n"
        if let ended { md += "ended: \(iso.string(from: ended))\n" }
        md += "---\n\n# Transcript\n\n"
        for u in store.utterances {
            var line = "- \(time.string(from: u.time)) \(u.text)"
            if let refs = refsByUtterance[u.id] {
                line += refs.map { "[^\($0)]" }.joined()
            }
            md += line + "\n"
        }

        if !footnotes.isEmpty {
            md += "\n# Cards\n\n"
            for (label, card) in footnotes {
                md += footnote(label: label, card: card)
            }
        }

        if !orphans.isEmpty {
            md += "\n# Other cards\n\n"
            for card in orphans {
                md += "## [\(card.kind)] \(card.title)\n\n\(card.body)\n\n"
            }
        }

        try? md.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Renders a card as a footnote definition. The body is indented 4 spaces
    /// per line so multi-paragraph cards stay inside the footnote.
    private func footnote(label: String, card: Card) -> String {
        var out = "[^\(label)]: **[\(card.kind)] \(card.title)**\n\n"
        for line in card.body.split(separator: "\n", omittingEmptySubsequences: false) {
            out += line.isEmpty ? "\n" : "    \(line)\n"
        }
        return out + "\n"
    }
}
