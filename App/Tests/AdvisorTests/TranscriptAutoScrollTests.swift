import CoreGraphics
import Foundation
import Testing

@testable import Advisor

private func viewport(
    visibleBottom: CGFloat,
    contentHeight: CGFloat = 1_000,
    containerHeight: CGFloat = 500
) -> TranscriptViewport {
    TranscriptViewport(
        visibleBottom: visibleBottom,
        contentHeight: contentHeight,
        containerHeight: containerHeight)
}

@Test func transcriptAutoScrollFollowsNewContentInitially() {
    #expect(TranscriptAutoScroll().followsTail)
}

@Test func transcriptAutoScrollStopsWhenViewportMovesUp() {
    var state = TranscriptAutoScroll()

    state.viewportChanged(
        from: viewport(visibleBottom: 1_000),
        to: viewport(visibleBottom: 900))

    #expect(!state.followsTail)
}

@Test func transcriptAutoScrollAccumulatesFractionalTrackpadMovement() {
    var state = TranscriptAutoScroll()
    let positions: [CGFloat] = stride(from: 1_000.0, through: 975.2, by: -0.4).map { $0 }

    for (previous, current) in zip(positions, positions.dropFirst()) {
        state.viewportChanged(
            from: viewport(visibleBottom: previous),
            to: viewport(visibleBottom: current))
    }

    #expect(!state.followsTail)
}

@Test func transcriptAutoScrollStaysOffUntilViewportNearsBottom() {
    var state = TranscriptAutoScroll()
    state.viewportChanged(
        from: viewport(visibleBottom: 1_000),
        to: viewport(visibleBottom: 900))

    state.viewportChanged(
        from: viewport(visibleBottom: 900),
        to: viewport(visibleBottom: 950))

    #expect(!state.followsTail)
}

@Test func transcriptAutoScrollResumesWithinOneLineOfBottom() {
    var state = TranscriptAutoScroll()
    state.viewportChanged(
        from: viewport(visibleBottom: 1_000),
        to: viewport(visibleBottom: 900))

    state.viewportChanged(
        from: viewport(visibleBottom: 900),
        to: viewport(visibleBottom: 976))

    #expect(state.followsTail)
}

@Test func transcriptAutoScrollDisablesAgainWhenGestureReversesFromBottom() {
    var state = TranscriptAutoScroll()
    state.viewportChanged(
        from: viewport(visibleBottom: 1_000),
        to: viewport(visibleBottom: 900))
    state.viewportChanged(
        from: viewport(visibleBottom: 900),
        to: viewport(visibleBottom: 980))

    state.viewportChanged(
        from: viewport(visibleBottom: 980),
        to: viewport(visibleBottom: 940))

    #expect(!state.followsTail)
}

@Test func transcriptContentGrowthAloneDoesNotDisableFollowing() {
    var state = TranscriptAutoScroll()

    state.viewportChanged(
        from: viewport(visibleBottom: 1_000, contentHeight: 1_000),
        to: viewport(visibleBottom: 1_000, contentHeight: 1_100))

    #expect(state.followsTail)
}

@Test func transcriptContentGrowthAfterReturningToBottomKeepsFollowing() {
    var state = TranscriptAutoScroll()
    state.viewportChanged(
        from: viewport(visibleBottom: 1_000),
        to: viewport(visibleBottom: 900))
    state.viewportChanged(
        from: viewport(visibleBottom: 900),
        to: viewport(visibleBottom: 980))

    state.viewportChanged(
        from: viewport(visibleBottom: 980, contentHeight: 1_000),
        to: viewport(visibleBottom: 980, contentHeight: 1_100))

    #expect(state.followsTail)
}

@Test func transcriptContainerResizeDoesNotCountAsUserScroll() {
    var state = TranscriptAutoScroll()

    state.viewportChanged(
        from: viewport(visibleBottom: 1_000, containerHeight: 500),
        to: viewport(visibleBottom: 900, containerHeight: 400))

    #expect(state.followsTail)
}

@Test func transcriptAutoScrollUsesOneLineBottomTolerance() {
    #expect(viewport(visibleBottom: 976).isAtBottom)
    #expect(!viewport(visibleBottom: 975.5).isAtBottom)
}

// Issue #109: a card that streams in place grows the feed, but adds no line
// or card. The trigger to follow the tail must change with it.
private func card(_ body: String, id: String = "c1", state: String = "streaming", activity: String? = nil) -> Card {
    Card(id: id, created: Date(timeIntervalSince1970: 0), kind: "answer", title: "T", body: body,
         state: state, activity: activity)
}

private let someLines = (0..<3).map { _ in Utterance(time: Date(), source: .them, text: "line", latencyMs: 0) }

private func content(
    cards: [Card] = [], lines: [Utterance] = someLines, notes: Int = 0
) -> TranscriptAutoScroll.Content {
    TranscriptAutoScroll.Content(
        utterances: lines,
        notes: (0..<notes).map { _ in EditorialNote(id: UUID(), time: Date(), text: "note") },
        cards: cards)
}

@Test func feedContentChangesWhenACardStreamsInPlace() {
    #expect(content(cards: [card("The answer")]) != content(cards: [card("The answer grows")]))
    #expect(content(cards: [card("abc")]) != content(cards: [card("xyz")]), "same length, other text")
}

@Test func feedContentChangesWithNewItemsAndCardProgress() {
    let base = content(cards: [card("A")], notes: 1)
    #expect(base == content(cards: [card("A")], notes: 1))
    #expect(base != content(cards: [card("A")], lines: someLines + someLines.prefix(1), notes: 1))
    #expect(base != content(cards: [card("A")], notes: 2))
    #expect(base != content(cards: [card("A"), card("B", id: "c2")], notes: 1))
    #expect(base != content(cards: [card("A", id: "c2")], notes: 1), "another card, same text")
    #expect(base != content(cards: [card("A", state: "done")], notes: 1))
    #expect(base != content(cards: [card("A", activity: "Searching")], notes: 1))
}

@Test func feedContentChangesWhenEchoDedupSwapsALine() {
    // Echo dedup removes a mic line and adds the system-audio line in one update.
    let swapped = Array(someLines.dropLast()) + [Utterance(time: Date(), source: .them, text: "echo", latencyMs: 0)]
    #expect(content(lines: someLines) != content(lines: swapped))
}

@Test func feedContentIgnoresWhatTheUserChangesOnACard() {
    var factCheck = card("A")
    factCheck.isExpanded = false
    let collapsed = content(cards: [factCheck])
    factCheck.isExpanded = true
    #expect(content(cards: [factCheck]) == collapsed, "an expand")
    factCheck.replying = true
    #expect(content(cards: [factCheck]) == collapsed, "the reply flag")
}

@Test func aContentChangeScrollsOnlyWhileFollowingAndNotWhileTyping() {
    var state = TranscriptAutoScroll()
    #expect(state.scrollsOnContentChange(editingText: false))
    #expect(!state.scrollsOnContentChange(editingText: true))
    state.viewportChanged(from: viewport(visibleBottom: 1_000), to: viewport(visibleBottom: 900))
    #expect(!state.scrollsOnContentChange(editingText: false))
}

// Issue #109: while cards stream, each update scrolls a following feed back to
// the bottom. A slow scroll up that stays within the tolerance must still stop
// the follow, or the user can never leave the tail.
@Test func aSmallScrollUpWithinTheToleranceStopsTheFollow() {
    var state = TranscriptAutoScroll()

    state.viewportChanged(
        from: viewport(visibleBottom: 1_000),
        to: viewport(visibleBottom: 997))

    #expect(!state.followsTail)
}

@Test func aCardThatShrinksAtTheBottomKeepsTheFollow() {
    var state = TranscriptAutoScroll()

    state.viewportChanged(
        from: viewport(visibleBottom: 1_000, contentHeight: 1_000),
        to: viewport(visibleBottom: 960, contentHeight: 960))

    #expect(state.followsTail)
}

@Test func aLayoutChangeThatMovesTheViewUpIsNoUserScroll() {
    var state = TranscriptAutoScroll()

    state.viewportChanged(
        from: viewport(visibleBottom: 1_000, contentHeight: 1_100),
        to: viewport(visibleBottom: 950, contentHeight: 1_060))

    #expect(state.followsTail)
}

@Test func aShrinkThatTheScrollViewClampsInALaterUpdateKeepsTheFollow() {
    // Seen in the dev build: the content gets shorter first, then the visible
    // bottom moves to the new end in the next update.
    var state = TranscriptAutoScroll()

    state.viewportChanged(
        from: viewport(visibleBottom: 1_277, contentHeight: 1_277),
        to: viewport(visibleBottom: 1_277, contentHeight: 1_178))
    state.viewportChanged(
        from: viewport(visibleBottom: 1_277, contentHeight: 1_178),
        to: viewport(visibleBottom: 1_178, contentHeight: 1_178))

    #expect(state.followsTail)
}

@Test func growthNearTheBottomAfterAScrollUpDoesNotStartTheFollowAgain() {
    var state = TranscriptAutoScroll()
    state.viewportChanged(
        from: viewport(visibleBottom: 1_000, contentHeight: 1_000),
        to: viewport(visibleBottom: 997, contentHeight: 1_000))

    state.viewportChanged(
        from: viewport(visibleBottom: 997, contentHeight: 1_000),
        to: viewport(visibleBottom: 997, contentHeight: 1_010))

    #expect(!state.followsTail)
}
