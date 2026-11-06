import SwiftUI

/// The Ask and Note popovers' shared body (issue #104): a title, a line saying
/// what happens to the text, a field that grows with it — Return submits, ⌥↵
/// starts a new line — and the submit button. The draft lives with the window,
/// so a click away that closes the popover keeps it.
struct ComposerForm: View {
    let title: String
    let prompt: String
    let placeholder: String
    let submitTitle: String
    let tint: ComposerTint
    @Binding var text: String
    /// The transcript line a right-clicked note goes under, quoted above the
    /// field; nil for the end of the transcript.
    var quote: String? = nil
    /// Drop `quote`, so the note goes at the end of the transcript instead.
    var onClearQuote: (() -> Void)? = nil
    let onSubmit: () -> Void

    @FocusState private var focused: Bool
    /// Where the caret goes on opening: the end of the draft. Focusing a field
    /// otherwise selects all of it, and the first key typed would replace a
    /// draft kept from a click away.
    @State private var selection: TextSelection?

    private var canSubmit: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textStrong)
            Text(prompt).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let quote {
                HStack(spacing: 4) {
                    Text("Under “\(quote)”")
                        .font(.system(size: 11).italic())
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let onClearQuote {
                        CardIconButton(system: "xmark", help: "Add it at the end instead", action: onClearQuote)
                    }
                }
            }
            TextField(placeholder, text: $text, selection: $selection, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit(submit)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 0.5))
            HStack {
                Text("⌥↵ new line").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                Spacer()
                Button(submitTitle, action: submit)
                    .buttonStyle(ComposerSubmitStyle(tint: tint))
                    .focusEffectDisabled()
                    .disabled(!canSubmit)
            }
        }
        // A fixed column, so a long quoted line truncates rather than widening
        // the popover past its field.
        .frame(width: 340)
        .padding(14)
        .onAppear { focused = true }
        // Once focused, which selects the whole field, put the caret at the end.
        .onChange(of: focused) { _, isFocused in
            if isFocused { selection = TextSelection(insertionPoint: text.endIndex) }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        onSubmit()
    }
}

/// The submit button's colours. Note's is green on its tint, as the Note card's
/// label is: white on dark mode's bright green is too faint to read.
struct ComposerTint {
    let fill: Color
    let text: Color

    static let ask = ComposerTint(fill: Theme.accent, text: Theme.onAccent)
    static let note = ComposerTint(fill: Theme.noteGreenTint, text: Theme.noteGreen)
}

/// The Ask / Add note button, dimmed while there's nothing to send.
private struct ComposerSubmitStyle: ButtonStyle {
    let tint: ComposerTint
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(tint.text)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(tint.fill, in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

/// The front window's Ask and Note popovers, for the menu bar's ⌘K and ⇧⌘N
/// (issue #104). A nil action greys its item out.
struct ComposerCommands {
    var ask: (() -> Void)?
    var note: (() -> Void)?
}

extension FocusedValues {
    @Entry var composer: ComposerCommands?
}
