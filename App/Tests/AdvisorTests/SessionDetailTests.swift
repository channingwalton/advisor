import Foundation
import Testing

@testable import Advisor

private let note = """
---
started: 2026-06-18T17:00:00Z
ended: 2026-06-18T17:34:00Z
context: Effect systems research talk
---

# Transcript

- 17:00:00 OCaml is adopting effect systems.

> **CONTEXT · OCaml effect systems**
>
> handlers added in OCaml 5.0, untyped by design
>
> _↳ "OCaml is adopting effect systems"_

- 17:00:05 More discussion follows.

# Follow-ups

> **Q · Which is production-ready?**
>
> OCaml 5 ships effects.
>
> _Asked 18:31 · 2026-06-18_
"""

@Test func contextBecomesTitle() {
    let d = SessionDetail.parse(contents: note, fallbackTitle: "fallback")
    #expect(d.title == "Effect systems research talk")
    #expect(d.durationMinutes == 34)
    #expect(d.gist == "OCaml is adopting effect systems.")
}

@Test func nameOverridesContextAsTitle() {
    let named = """
    ---
    name: Weekly sync
    started: 2026-06-18T17:00:00Z
    context: Effect systems research talk
    ---

    # Transcript

    - 17:00:00 hi
    """
    let d = SessionDetail.parse(contents: named, fallbackTitle: "fallback")
    #expect(d.title == "Weekly sync")
    #expect(d.name == "Weekly sync")
    // Context stays exposed even when a name overrides the title, so search can
    // still match it.
    #expect(d.context == "Effect systems research talk")
}

@Test func unnamedSessionExposesEmptyName() {
    let d = SessionDetail.parse(contents: note, fallbackTitle: "fallback")
    #expect(d.name == "")
    #expect(d.title == "Effect systems research talk") // still context-titled
}

@Test func missingContextFallsBackToTitle() {
    let bare = "---\nstarted: 2026-06-18T17:00:00Z\n---\n\n# Transcript\n\n- 17:00:00 hi"
    let d = SessionDetail.parse(contents: bare, fallbackTitle: "Thu 18 Jun, 5:00 PM")
    #expect(d.title == "Thu 18 Jun, 5:00 PM")
}

@Test func surfacedCardsParsedAndQuestionsSplitOut() {
    let d = SessionDetail.parse(contents: note, fallbackTitle: "x")
    #expect(d.cards == [
        SurfacedCard(
            label: "CONTEXT", title: "OCaml effect systems",
            snippet: "handlers added in OCaml 5.0, untyped by design"),
    ])
    #expect(d.questions == [
        AskedQuestion(question: "Which is production-ready?", askedAt: "18:31"),
    ])
}

@Test func askedTimeAnchorsToFooterNotAnswerBody() {
    // The answer body mentions "Asked 09:99"; the real stamp is the `_Asked …_`
    // footer. askedAt must anchor to the footer, not the first "Asked " in the
    // block (issue #65).
    let withDecoy = """
---
context: x
---

# Follow-ups

> **Q · When did it start?**
>
> They Asked 09:99 to begin, per the notes.
>
> _Asked 14:30 · 2026-06-18_
"""
    let d = SessionDetail.parse(contents: withDecoy, fallbackTitle: "x")
    #expect(d.questions == [
        AskedQuestion(question: "When did it start?", askedAt: "14:30"),
    ])
}

@Test func frontmatterParsesContext() {
    #expect(SessionArchive.frontmatter(note)["context"] == "Effect systems research talk")
}

@Test func inlineWritesContextToFrontmatter() {
    let md = SessionMarkdown.inline(
        utterances: [], cards: [], started: Date(timeIntervalSince1970: 0), ended: nil,
        context: "Q3 board review\nsecond line")
    // Multi-line context collapses to one frontmatter scalar.
    #expect(md.contains("context: Q3 board review second line\n"))
}

@Test func cardCountIsPluralised() {
    #expect(SessionDetail.cardCount(0) == "0 cards")
    #expect(SessionDetail.cardCount(1) == "1 card")
    #expect(SessionDetail.cardCount(9) == "9 cards")
}

@Test func detailKeepsParagraphTimesAlongsideBlocks() {
    let d = SessionDetail.parse(contents: note, fallbackTitle: "fallback")
    #expect(d.blockTimes.count == d.blocks.count)
    #expect(d.blockTimes.compactMap { $0 } == ["17:00", "17:00"])
}
