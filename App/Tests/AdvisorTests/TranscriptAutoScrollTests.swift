import CoreGraphics
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
