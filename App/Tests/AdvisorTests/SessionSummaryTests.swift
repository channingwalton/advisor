import Testing
import Foundation

@testable import Advisor

/// A minimal saved note in the format `SessionMarkdown.inline` writes.
private let note = "---\nstarted: x\n---\n\n# Transcript\n\n- 17:00:00 hello\n"

@Test func upsertInsertsSummaryBeforeTranscript() {
    let out = SessionArchive.upsertingSummary(into: note, summary: "The gist.")

    #expect(out.contains("# Summary\n\n> **SUMMARY**\n>\n> The gist."))
    let s = out.range(of: "# Summary")
    let tr = out.range(of: "# Transcript")
    #expect(s != nil && tr != nil && s!.lowerBound < tr!.lowerBound)
    // The transcript is preserved.
    #expect(out.contains("- 17:00:00 hello"))
}

@Test func upsertReplacesExistingSummaryInPlace() {
    let once = SessionArchive.upsertingSummary(into: note, summary: "First.")
    let twice = SessionArchive.upsertingSummary(into: once, summary: "Second.")

    // Exactly one summary section, carrying only the latest text.
    #expect(twice.components(separatedBy: "# Summary").count - 1 == 1)
    #expect(twice.contains("> Second."))
    #expect(!twice.contains("> First."))
    #expect(twice.contains("- 17:00:00 hello"))
}

@Test func upsertReplaceConvergesWithFreshInsert() {
    // Re-summarising must land on the same bytes as a first-time insert of the
    // same text, so an old summary leaves no residue.
    let replaced = SessionArchive.upsertingSummary(
        into: SessionArchive.upsertingSummary(into: note, summary: "First."),
        summary: "Final.")
    let fresh = SessionArchive.upsertingSummary(into: note, summary: "Final.")

    #expect(replaced == fresh)
}

@Test func upsertedSummaryParsesAsAHeadingAndCardBlock() {
    let out = SessionArchive.upsertingSummary(into: note, summary: "Recap.")
    let blocks = TranscriptDoc.blocks(from: SessionArchive.strippingFrontmatter(out))

    #expect(blocks.contains(.heading("Summary")))
    #expect(
        blocks.contains {
            if case .card(let m) = $0 { return m.contains("**SUMMARY**") }
            return false
        })
}

@Test func liveAndSavedSummarySectionsAreByteIdentical() {
    // The live writer (inline) and a saved-note upsert must produce the same
    // `# Summary` section for the same text, so "update existing" works whether a
    // session was summarised while recording or later from the browser.
    let t = Date(timeIntervalSince1970: 1_000)
    let card = Card(
        id: "c1", created: t, kind: "summary", title: "Summary", body: "Cross-surface.",
        state: "done", triggerId: nil, triggerQuote: nil)

    let live = SessionMarkdown.inline(utterances: [], cards: [card], started: t, ended: nil)
    let bare = SessionMarkdown.inline(utterances: [], cards: [], started: t, ended: nil)
    let upserted = SessionArchive.upsertingSummary(into: bare, summary: "Cross-surface.")

    #expect(live == upserted)
}
