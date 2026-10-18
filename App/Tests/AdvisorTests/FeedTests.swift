import Foundation
import Testing

@testable import Advisor

// MARK: saved card parsing

@Test func savedCardParsesContextHeaderBodyAndTriggerQuote() {
    let card = SavedCard.card(
        from: "**CONTEXT · OCaml effect systems**\n\nhandlers added in OCaml 5.0\n\n_↳ OCaml is adopting effect systems._",
        id: "s-1")
    #expect(card.id == "s-1")
    #expect(card.kind == "context")
    #expect(card.title == "OCaml effect systems")
    #expect(card.body == "handlers added in OCaml 5.0")
    #expect(card.triggerQuote == "OCaml is adopting effect systems.")
    #expect(card.footnote == nil)
    #expect(card.state == "done")
}

@Test func savedCardMapsVerdictLabelsToFactChecks() {
    let cases: [(String, Verdict?)] = [
        ("VERIFIED", .verified), ("NEEDS CONTEXT", .needsContext),
        ("MISLEADING", .misleading), ("FACT-CHECK", nil),
    ]
    for (label, verdict) in cases {
        let card = SavedCard.card(from: "**\(label) · A claim**\n\nEvidence.", id: "x")
        #expect(card.kind == "factcheck")
        #expect(card.verdict == verdict)
        #expect(card.title == "A claim")
    }
}

@Test func savedCardSplitsGroundedFooterAndSources() {
    let card = SavedCard.card(
        from: "**ANSWER · Who wrote it?**\n\nAda did.\n\n_Grounded in the live conversation_ · [Wiki](https://w.example) · [Doc](https://d.example)",
        id: "x")
    #expect(card.kind == "answer")
    #expect(card.body == "Ada did.")
    #expect(card.footnote == nil)
    #expect(card.triggerQuote == nil)
    #expect(card.sources == [
        Citation(label: "Wiki", url: "https://w.example"),
        Citation(label: "Doc", url: "https://d.example"),
    ])
}

@Test func savedCardKeepsATrailingLinkLineInTheBody() {
    // Indistinguishable from a sources-only footer, so it stays where it renders
    // as the body's own link rather than moving into the footer.
    let card = SavedCard.card(from: "**CONTEXT · X**\n\nBody.\n\n[A](https://a.example)", id: "x")
    #expect(card.body == "Body.\n\n[A](https://a.example)")
    #expect(card.sources.isEmpty)
}

@Test func savedCardSourceLabelsMayContainTheSeparator() {
    let card = SavedCard.card(
        from: "**ANSWER · Q**\n\nA.\n\n_Grounded in the live conversation_ · [Pull requests · openai/codex · GitHub](https://github.com/openai/codex/pulls) · [Foo](https://en.wikipedia.org/wiki/Foo_(bar))",
        id: "x")
    #expect(card.body == "A.")
    #expect(card.sources == [
        Citation(label: "Pull requests · openai/codex · GitHub", url: "https://github.com/openai/codex/pulls"),
        Citation(label: "Foo", url: "https://en.wikipedia.org/wiki/Foo_(bar)"),
    ])
}

@Test func savedCardKeepsATrailingItalicBodyLineThatIsNotAFooter() {
    let card = SavedCard.card(from: "**CONTEXT · X**\n\nBody.\n\n_Next review Tuesday_", id: "x")
    #expect(card.body == "Body.\n\n_Next review Tuesday_")
    #expect(card.footnote == nil)
    #expect(card.triggerQuote == nil)
}

@Test func savedSummaryNeverHasAFooter() {
    let card = SavedCard.card(from: "**SUMMARY**\n\nGist.\n\n[Spec](https://s.example)", id: "x")
    #expect(card.body == "Gist.\n\n[Spec](https://s.example)")
    #expect(card.sources.isEmpty)
}

@Test func savedBlockquoteWithoutHeaderHasNoKind() {
    let card = SavedCard.card(from: "A quote I pasted.\n\n_Grounded in the live conversation_", id: "x")
    #expect(card.kind == "")
    #expect(FeedCardView.kindName(card) == "")
    #expect(card.body == "A quote I pasted.\n\n_Grounded in the live conversation_")
}

@Test func savedBlockquoteWithUnknownBoldFirstLineKeepsItInTheBody() {
    let card = SavedCard.card(from: "**Tip:** use **this**\n\nMore.", id: "x")
    #expect(card.kind == "")
    #expect(card.title == "")
    #expect(card.body == "**Tip:** use **this**\n\nMore.")
}

@Test func savedSummaryCardHasLabelOnlyHeader() {
    let card = SavedCard.card(from: "**SUMMARY**\n\nThe gist.\n- point", id: "x")
    #expect(card.kind == "summary")
    #expect(card.title == "Summary")
    #expect(card.body == "The gist.\n- point")
}

@Test func savedFollowUpKeepsAskedFooterAsFootnote() {
    let card = SavedCard.card(
        from: "**Q · What next?**\n\nShip it.\n\n_Asked 10:15:02 · 2026-10-05_", id: "x")
    #expect(card.kind == "question")
    #expect(card.title == "What next?")
    #expect(card.body == "Ship it.")
    #expect(card.footnote == "Asked 10:15:02 · 2026-10-05")
}

@Test func savedCardWithoutHeaderIsAllBody() {
    let card = SavedCard.card(from: "Just a body.\n- item", id: "x")
    #expect(card.kind == "")
    #expect(card.title == "")
    #expect(card.body == "Just a body.\n- item")
}

@Test func savedCardRoundTripsWhatTheWriterWrites() throws {
    let t = Date(timeIntervalSince1970: 1_750_000_000)
    let written = Card(
        id: "c1", created: t, kind: "factcheck", title: "Rust is older than Go",
        body: "**False.** Go shipped first.\n\n- Go: 2009\n- Rust: 2010",
        state: "done", triggerQuote: "Rust is older than Go",
        sources: [Citation(label: "Go", url: "https://go.dev")], verdict: .misleading)
    let md = SessionMarkdown.inline(
        utterances: [Utterance(time: t, source: .them, text: "Rust is older than Go", latencyMs: 0)],
        cards: [written], started: t, ended: t)
    let blocks = TranscriptDoc.blocks(from: SessionArchive.strippingFrontmatter(md))
    let inner = try #require(blocks.compactMap { b -> String? in
        if case .card(let m) = b { m } else { nil }
    }.first)

    let card = SavedCard.card(from: inner, id: "s")
    #expect(card.kind == written.kind)
    #expect(card.verdict == written.verdict)
    #expect(card.title == written.title)
    #expect(card.body == written.body)
    #expect(card.triggerQuote == written.triggerQuote)
    #expect(card.sources == written.sources)
}

@Test func cardKindNameIsSentenceCaseOrVerdict() {
    func name(_ header: String) -> String { FeedCardView.kindName(SavedCard.card(from: header, id: "x")) }
    #expect(name("**CONTEXT · x**") == "Context")
    #expect(name("**NEEDS CONTEXT · x**") == "Needs context")
    #expect(name("**FACT-CHECK · x**") == "Fact-check")
    #expect(name("**Q · Which is production-ready?**") == "Question")
    #expect(name("**SUMMARY**") == "Summary")
    #expect(name("**ANSWER · x**") == "Answer")
}

// MARK: live feed

private func at(_ h: Int, _ m: Int, _ s: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: h, minute: m, second: s))!
}

private func paragraphs(_ item: FeedItem) -> [FeedParagraph] {
    if case .transcript(let ps) = item { ps } else { [] }
}

@Test func liveFeedJoinsCloseUtterancesAndSplitsOnGaps() {
    let a = Utterance(time: at(17, 0, 0), source: .me, text: "One", latencyMs: 0)
    let b = Utterance(time: at(17, 0, 2), source: .them, text: "two", latencyMs: 0)
    let c = Utterance(time: at(17, 1, 0), source: .me, text: "Three", latencyMs: 0)
    let items = Feed.grouped(Feed.live(utterances: [a, b, c], cards: [], notes: []), hideTranscript: false)

    #expect(items.count == 1)
    let ps = paragraphs(items[0])
    #expect(ps.map(\.text) == ["One two", "Three"])
    #expect(ps.map(\.time) == ["17:00", "17:01"])
    #expect(ps[0].lines.map(\.id) == [a.id.uuidString, b.id.uuidString])
}

@Test func liveFeedPlacesNoteThenCardUnderTheirLine() {
    let u = Utterance(time: at(17, 0, 0), source: .me, text: "Line", latencyMs: 0)
    let later = Utterance(time: at(17, 0, 1), source: .me, text: "after", latencyMs: 0)
    let card = Card(id: "c", created: u.time, kind: "answer", title: "T", body: "B", state: "done")
    let note = EditorialNote(id: UUID(), time: u.time, text: "N")
    let items = Feed.grouped(
        Feed.live(utterances: [later, u], cards: [card], notes: [note]), hideTranscript: false)

    #expect(items.map(\.id) == [
        "t-\(u.id.uuidString)", "n-\(note.id.uuidString)", "c-c", "t-\(later.id.uuidString)",
    ])
}

// MARK: saved feed

@Test func savedFeedMirrorsBlocksWithTimesAndHidesTranscriptHeading() {
    let blocks: [TranscriptBlock] = [
        .heading("Summary"), .card("**SUMMARY**\n\nGist."), .heading("Transcript"),
        .paragraph("Hello there."), .paragraph("Next."), .note("Mine"),
        .card("**ANSWER · Q**\n\nA."),
    ]
    let times: [String?] = [nil, nil, nil, "17:00", "17:05", nil, nil]
    let ids = Feed.savedIds(blocks)
    let items = Feed.grouped(Feed.saved(blocks: blocks, times: times), hideTranscript: false)

    #expect(items.map(\.id) == ["h-0", "c-\(ids[1]!)", "t-3", "n-\(ids[5]!)", "c-\(ids[6]!)"])
    let ps = paragraphs(items[2])
    #expect(ps.map(\.text) == ["Hello there.", "Next."])
    #expect(ps.map(\.time) == ["17:00", "17:05"])
    #expect(ps.map(\.id) == ["3", "4"])
}

@Test func hidingTranscriptKeepsOnlyCardsAndNotes() {
    let blocks: [TranscriptBlock] = [
        .paragraph("Hello."), .card("**ANSWER · Q**\n\nA."), .heading("Follow-ups"),
        .note("Mine"), .paragraph("Bye."),
    ]
    let items = Feed.grouped(
        Feed.saved(blocks: blocks, times: Array(repeating: nil, count: blocks.count)),
        hideTranscript: true)

    let ids = Feed.savedIds(blocks)
    #expect(items.map(\.id) == ["c-\(ids[1]!)", "n-\(ids[3]!)"])
}

@Test func savedIdsFollowContentNotOffset() {
    let alpha = TranscriptBlock.card("**CONTEXT · A**\n\nx")
    let note = TranscriptBlock.note("Mine")
    let before = Feed.savedIds([.paragraph("Hi."), alpha, .heading("Follow-ups"), note])
    let after = Feed.savedIds([alpha, note])

    #expect(before[0] == nil && before[2] == nil)
    #expect(before[1] == after[0])
    #expect(before[3] == after[1])
}

@Test func savedIdsTellIdenticalBlocksApart() {
    let alpha = TranscriptBlock.card("**CONTEXT · A**\n\nx")
    let ids = Feed.savedIds([alpha, .paragraph("Hi."), alpha])
    #expect(ids[0] != nil && ids[2] != nil && ids[0] != ids[2])
    #expect(Feed.savedIds([alpha]) == [ids[0]])
}

// MARK: saved collapse

@Test func savedFactChecksStartCollapsedLikeLiveOnes() {
    #expect(SavedCard.card(from: "**VERIFIED · X**\n\nY.", id: "a").isExpanded == false)
    #expect(SavedCard.card(from: "**CONTEXT · X**\n\nY.", id: "b").isExpanded == true)
}

private func expansion(_ items: [FeedItem]) -> [Bool] {
    items.compactMap { if case .card(let c) = $0 { c.isExpanded } else { nil } }
}

@Test func expansionOverridesApplyByCardIdOverTheDisplayedList() {
    let blocks: [TranscriptBlock] = [
        .paragraph("Hi."), .card("**CONTEXT · A**\n\nx"), .card("**VERIFIED · B**\n\ny"),
    ]
    let ids = Feed.savedIds(blocks)
    let shown = Feed.grouped(Feed.saved(blocks: blocks, times: [nil, nil, nil]), hideTranscript: true)
    #expect(expansion(shown) == [true, false])

    let toggled = Feed.applyingExpansion([ids[1]!: false, ids[2]!: true], to: shown)
    #expect(expansion(toggled) == [false, true])
}

@Test func cardsWithNothingToShowCollapsedCannotCollapse() {
    #expect(FeedCardView.canCollapse(SavedCard.card(from: "Pasted quote.", id: "x")) == false)
    #expect(FeedCardView.canCollapse(SavedCard.card(from: "**SUMMARY**\n\nGist.", id: "x")) == true)
    #expect(FeedCardView.canCollapse(SavedCard.card(from: "**CONTEXT · A**\n\nx", id: "x")) == true)
}

// MARK: pending research cards

@Test func pendingCardsShowUnderTheirParagraph() {
    let blocks: [TranscriptBlock] = [.paragraph("One."), .paragraph("Two."), .card("**ANSWER · Q**\n\nA.")]
    let pending = Card(id: "p", created: .distantPast, kind: "context", title: "One.", body: "…", state: "pending")
    let stray = Card(id: "q", created: .distantPast, kind: "answer", title: "?", body: "…", state: "pending")
    let items = Feed.inserting([(afterParagraph: "0", card: pending), (afterParagraph: "9", card: stray)],
        into: Feed.saved(blocks: blocks, times: [nil, nil, nil]))

    #expect(items.map(\.id) == ["t-0", "c-p", "t-1", "c-\(Feed.savedIds(blocks)[2]!)", "c-q"])
}

@Test func researchActionsFollowTheTriggerToggles() {
    var triggers = AdvisorConfig.Triggers()
    #expect(TranscriptAction.research(for: triggers).map(\.kind) == ["answer", "context", "factcheck"])
    triggers.context = false
    #expect(TranscriptAction.research(for: triggers).map(\.title) == ["Answer", "Fact check"])
}

/// A saved paragraph keeps its transcript lines as the feed's lines, joined by
/// single spaces as the text, so the correction menu can tell a selection across
/// a line join (issue #92) as it can live.
@Test func savedParagraphsKeepTheirLines() {
    let blocks: [TranscriptBlock] = [.paragraph("Hello there. Next."), .card("**ANSWER · Q**\n\nA.")]
    let items = Feed.saved(blocks: blocks, times: [nil, nil], lines: [["Hello there.", "Next."], []])

    let ps = paragraphs(items[0])
    #expect(ps.map(\.text) == ["Hello there. Next."])
    #expect(ps.first?.lines.map(\.text) == ["Hello there.", "Next."])
    #expect(ps.first?.lines.map(\.id) == ["0", "0"])
}
