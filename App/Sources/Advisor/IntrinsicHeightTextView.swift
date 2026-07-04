import AppKit

/// An `NSTextView` that reports its wrapped-text height through
/// `intrinsicContentSize` while leaving width flexible (`noIntrinsicMetric`), so
/// SwiftUI lays it out like a wrapping label and the row height always matches
/// the drawn wrap (issue #12). The transcript's `ActionTextView` and the card's
/// markdown view both subclass this, so the sizing machinery lives in one place
/// rather than being copied (and risking divergence for exactly the bug it fixes).
class IntrinsicHeightTextView: NSTextView {
    private var lastLaidOutWidth: CGFloat = -1

    /// Height that fits the text at the current width; width stays flexible so
    /// the view fills its column. SwiftUI reads this for the row height, so it
    /// always matches the drawn wrap (issue #12).
    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let container = textContainer else {
            return super.intrinsicContentSize
        }
        lm.ensureLayout(for: container)
        return NSSize(
            width: NSView.noIntrinsicMetric, height: ceil(lm.usedRect(for: container).height))
    }

    // Whenever SwiftUI gives us a new width (window resize, session switch,
    // sidebar reflow) the container has already tracked to it via super, so the
    // freshly invalidated intrinsic height reflects the new wrap. Guarded on a
    // real width change to avoid a layout loop.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(newSize.width - lastLaidOutWidth) > 0.5 {
            lastLaidOutWidth = newSize.width
            invalidateIntrinsicContentSize()
        }
    }
}
