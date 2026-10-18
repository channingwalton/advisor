import AppKit
import SwiftUI

// MARK: - Folder context button (issue #36)

/// A folder header's context button, left of the record button: opens a popover to
/// edit the folder's context — the seed every recording started in this folder
/// inherits. The filled glyph shows a context is set.
/// Owns its popover/draft state so each folder row gets an independent editor.
struct FolderContextButton: View {
    let folder: String
    /// The folder's current saved context, for the tinted state and seeding the draft.
    let context: String
    /// The saved-contexts library, offered by the popover's Load menu.
    let library: [SavedContext]
    let onSave: (String) -> Void
    @State private var show = false
    @State private var draft = ""

    private var hasContext: Bool { !context.isEmpty }

    var body: some View {
        Button {
            draft = context
            show = true
        } label: {
            Image(systemName: hasContext ? "text.bubble.fill" : "text.bubble")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(hasContext ? "Edit context for “\(folder)”" : "Set context for “\(folder)”")
        .popover(isPresented: $show, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Folder context").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textStrong)
                Text("Seeds the context of every recording started in “\(folder)”. "
                    + "Editable per session.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $draft)
                    .font(.system(size: 12.5))
                    .frame(width: 320, height: 100)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 0.5))
                HStack {
                    SavedContextMenu(contexts: library) { draft = $0.text }
                    Spacer()
                    Button("Save") {
                        onSave(draft)
                        show = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
    }
}

// MARK: - Folder tags button (issue #76)

/// A folder header's tag button: edits the defaults inherited by new recordings
/// started in the folder. Existing sessions and sessions moved into it are unchanged.
struct FolderTagsButton: View {
    let folder: String
    let tags: [String]
    let library: [SavedTag]
    let onChange: ([String]) -> Void
    @State private var show = false

    private var hasTags: Bool { !tags.isEmpty }

    var body: some View {
        Button { show.toggle() } label: {
            HStack(spacing: 2) {
                Image(systemName: hasTags ? "tag.fill" : "tag")
                    .font(.system(size: 11))
                if hasTags {
                    Text("\(tags.count)")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(hasTags ? "Edit tags for “\(folder)”" : "Set tags for “\(folder)”")
        .popover(isPresented: $show, arrowEdge: .bottom) {
            SessionTagsEditor(tags: tags, library: library, onChange: onChange)
        }
    }
}
