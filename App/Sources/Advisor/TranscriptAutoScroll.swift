import CoreGraphics

struct TranscriptViewport: Equatable {
    let visibleBottom: CGFloat
    let contentHeight: CGFloat
    let containerHeight: CGFloat

    var isAtBottom: Bool {
        visibleBottom >= contentHeight - TranscriptAutoScroll.bottomTolerance
    }

    func movedAway(from previous: TranscriptViewport) -> Bool {
        containerHeight == previous.containerHeight
            && visibleBottom < previous.visibleBottom
    }
}

struct TranscriptAutoScroll {
    /// Roughly one rendered transcript line. This avoids making users land on a
    /// fractional-pixel exact bottom before tail-following resumes.
    static let bottomTolerance: CGFloat = 24

    private(set) var followsTail = true

    mutating func viewportChanged(from previous: TranscriptViewport, to current: TranscriptViewport) {
        if current.isAtBottom {
            followsTail = true
        } else if current.movedAway(from: previous) {
            followsTail = false
        }
    }
}
