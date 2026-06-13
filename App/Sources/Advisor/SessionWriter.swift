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

        var md = "---\n"
        md += "started: \(iso.string(from: started))\n"
        if let ended { md += "ended: \(iso.string(from: ended))\n" }
        md += String(format: "cost_usd: %.4f\n", store.costUsd)
        md += "---\n\n# Transcript\n\n"
        for u in store.utterances {
            md += "- \(time.string(from: u.time)) \(u.text)\n"
        }
        md += "\n# Cards\n\n"
        for card in store.cards where card.state == "done" || card.state == "failed" {
            md += "## [\(card.kind)] \(card.title)\n\n\(card.body)\n\n"
        }
        try? md.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
