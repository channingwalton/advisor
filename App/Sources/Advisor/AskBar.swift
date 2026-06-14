import SwiftUI

/// Bottom Ask bar: an input (sparkle glyph + placeholder + ⌘↵ hint) and a
/// solid Ask button. ⌘↵ or Return submits.
struct AskBar: View {
    @Binding var text: String
    let onSubmit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkle").font(.system(size: 13))
                        .foregroundStyle(Theme.accent)
                    TextField(
                        "Ask anything about this conversation — or beyond it…", text: $text
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit(onSubmit)
                    Text("⌘ ↵").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Theme.surfaceCard, in: RoundedRectangle(cornerRadius: Theme.Metric.inputRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metric.inputRadius)
                        .stroke(Theme.hairline, lineWidth: 0.5))

                Button("Ask", action: onSubmit)
                    .buttonStyle(AskButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, Theme.Metric.contentSidePad)
        .padding(.vertical, 12)
        .background(Theme.surfaceTitlebar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }
}

/// Solid accent Ask/submit button, 44 pt tall.
struct AskButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 20)
            .frame(height: 44)
            .background(
                configuration.isPressed ? Theme.accentHover : Theme.accent,
                in: RoundedRectangle(cornerRadius: Theme.Metric.inputRadius))
    }
}
