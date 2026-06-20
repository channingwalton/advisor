import SwiftUI

/// A small coloured capsule for a session tag (issue #15). The colour comes from
/// the tag's stored hex; the fill is that colour at low opacity so it reads in
/// both light and dark mode. When `onRemove` is set, a trailing ✕ removes the tag
/// (used by the tag-editing controls); without it, the pill is display-only (the
/// session list rows).
struct TagPill: View {
    let name: String
    let colorHex: String
    var onRemove: (() -> Void)?

    init(name: String, colorHex: String, onRemove: (() -> Void)? = nil) {
        self.name = name
        self.colorHex = colorHex
        self.onRemove = onRemove
    }

    var body: some View {
        let color = Color(tagHex: colorHex)
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(color.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("Remove tag")
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, onRemove == nil ? 7 : 5)
        .padding(.vertical, 2.5)
        .background(color.opacity(0.15), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.30), lineWidth: 0.5))
    }
}

/// A simple left-to-right wrapping layout, so a row of tag pills flows onto the
/// next line instead of clipping or forcing a horizontal scroll. SwiftUI has no
/// built-in flow layout; this covers the few-pills case the tag UI needs.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > bounds.width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            sub.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
