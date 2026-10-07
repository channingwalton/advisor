import SwiftUI

/// The Sessions window's Answer panel: an Ask answer or a Summarise streaming in
/// under the transcript. The header sits outside the scroll view, so its Stop
/// button stays in reach however long the answer grows, and never covers text.
struct AnswerPanel: View {
    let title: String
    let titleColor: Color
    let markdown: String
    let isRunning: Bool
    /// Stops the request; nil shows no button.
    let stop: (() -> Void)?
    let stopHelp: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if isRunning { ProgressView().controlSize(.small).scaleEffect(0.7) }
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(titleColor)
                Spacer(minLength: 0)
                if isRunning, let stop {
                    CardIconButton(system: "xmark.circle.fill", help: stopHelp, action: stop)
                }
            }
            // The Stop button's height, held when it goes, so the answer
            // doesn't jump as it finishes.
            .frame(minHeight: 22)
            ScrollView {
                MarkdownText(markdown: markdown, style: .answer)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceCard, in: RoundedRectangle(cornerRadius: Theme.Metric.cardRadius))
        .shadow(color: Theme.cardShadow, radius: 12, y: 4)
    }
}
