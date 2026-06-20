import SwiftUI

/// The shared tag-assignment UI (issue #15): the session's applied tags as
/// removable pills, plus a pick-list of the remaining library tags to apply.
/// Assigns *existing* tags only — tags are created and coloured in
/// Preferences ▸ Tags. Hosted in a popover by `TagsChip` (live toolbar and
/// Sessions browser detail).
struct SessionTagsEditor: View {
    let tags: [String]
    let library: [SavedTag]
    let onChange: ([String]) -> Void

    /// Colour for an applied tag; a deleted/unknown tag falls back to neutral
    /// grey (it can still be removed, even though it no longer renders on cards).
    private func colorHex(_ name: String) -> String {
        TagLibrary.named(name, in: library)?.colorHex ?? "0x8A8B95"
    }

    private var available: [SavedTag] {
        TagLibrary.suggestions(library, applied: tags)
    }

    private func add(_ name: String) {
        onChange(tags + [name])
    }

    private func remove(_ name: String) {
        onChange(tags.filter { $0.caseInsensitiveCompare(name) != .orderedSame })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tags").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textStrong)
            if !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { name in
                        TagPill(name: name, colorHex: colorHex(name)) { remove(name) }
                    }
                }
            }
            // Separate the applied tags (removable) from the ones still available
            // to add, so the two groups read distinctly.
            if !tags.isEmpty && !available.isEmpty {
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
            }
            picker
        }
        .padding(14)
        .frame(width: 240)
        // Suppress the system keyboard-focus ring on the pill ✕ and pick-list rows.
        .focusEffectDisabled()
    }

    @ViewBuilder private var picker: some View {
        if library.isEmpty {
            Text("No tags yet. Create them in Preferences ▸ Tags.")
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
        } else if available.isEmpty {
            Text("All tags applied.")
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(available) { tag in
                    Button { add(tag.name) } label: {
                        HStack {
                            TagPill(name: tag.name, colorHex: tag.colorHex)
                            Spacer(minLength: 8)
                            Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// A chip that opens `SessionTagsEditor` in a popover — a tag glyph plus the
/// applied-tag count, matching the Name/Context chips. Used in the live toolbar
/// and the Sessions browser detail header.
struct TagsChip: View {
    let tags: [String]
    let library: [SavedTag]
    let onChange: ([String]) -> Void

    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "tag").font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Text("Tags").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textBody)
                if !tags.isEmpty {
                    Text("\(tags.count)").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(
                Theme.surfaceControl, in: RoundedRectangle(cornerRadius: Theme.Metric.buttonRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metric.buttonRadius)
                    .stroke(Theme.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show, arrowEdge: .bottom) {
            SessionTagsEditor(tags: tags, library: library, onChange: onChange)
        }
        .help("Session tags")
    }
}
