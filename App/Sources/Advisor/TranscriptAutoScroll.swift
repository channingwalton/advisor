import CoreGraphics
import Foundation

struct TranscriptViewport: Equatable {
    let visibleBottom: CGFloat
    let contentHeight: CGFloat
    let containerHeight: CGFloat

    var isAtBottom: Bool {
        visibleBottom >= contentHeight - TranscriptAutoScroll.bottomTolerance
    }

    /// A user scroll up: the visible bottom moves up while the container and
    /// the content keep their sizes. A layout change, such as a card that gets
    /// shorter at the bottom, changes the content size (issue #109). The scroll
    /// view then clamps the visible bottom to the new end in a later update,
    /// from a visible bottom past the end of the content, where a user scroll
    /// does not start.
    func movedAway(from previous: TranscriptViewport) -> Bool {
        containerHeight == previous.containerHeight
            && contentHeight == previous.contentHeight
            && previous.visibleBottom <= previous.contentHeight
            && visibleBottom < previous.visibleBottom
    }
}

struct TranscriptAutoScroll {
    /// Roughly one rendered transcript line. This avoids making users land on a
    /// fractional-pixel exact bottom before tail-following resumes.
    static let bottomTolerance: CGFloat = 24

    private(set) var followsTail = true

    /// A user scroll up stops the follow, also within the tolerance: while
    /// cards stream, each update scrolls a following feed back to the bottom,
    /// so a slow scroll never left the tolerance (issue #109). A move down to
    /// within the tolerance starts it again. Growth alone does not: after a
    /// small scroll up, the view can still be within the tolerance.
    mutating func viewportChanged(from previous: TranscriptViewport, to current: TranscriptViewport) {
        if current.movedAway(from: previous) {
            followsTail = false
        } else if current.isAtBottom, current.visibleBottom > previous.visibleBottom {
            followsTail = true
        }
    }

    /// Whether a change of the feed's content scrolls it to the bottom: only
    /// while it follows the tail, and not while the user types in an editable
    /// field, where a scroll takes the focus away (issue #37).
    func scrollsOnContentChange(editingText: Bool) -> Bool {
        followsTail && !editingText
    }

    /// The content of the live feed that the speech engine and the sidecar
    /// supply: the lines, the notes, and the text, state and activity of each
    /// card. A change is the trigger to follow the tail. A card that streams in
    /// place changes it, although it adds no item (issue #109). An expand or a
    /// collapse does not change it, so it does not scroll by itself.
    struct Content: Equatable {
        struct CardContent: Equatable {
            let id: String
            let body: String
            let state: String
            let activity: String?
        }

        let lines: Int
        /// Echo dedup can remove a line and add one in the same update, so the
        /// count alone does not change.
        let newestLine: UUID?
        let notes: Int
        let cards: [CardContent]

        init(utterances: [Utterance], notes: [EditorialNote], cards: [Card]) {
            lines = utterances.count
            newestLine = utterances.last?.id
            self.notes = notes.count
            self.cards = cards.map {
                CardContent(id: $0.id, body: $0.body, state: $0.state, activity: $0.activity)
            }
        }
    }
}
