import AppKit
import SwiftUI

/// First-run terms sheet (`TermsAcceptance`): blocks the Sessions window until
/// the current TERMS.md version is accepted. Decline quits — no acceptance, no
/// use. Re-presented when `TermsAcceptance.currentVersion` moves past the
/// accepted version.
struct TermsSheet: View {
    let onAccept: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Terms of Use")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textStrong)
                Text(
                    "In short: you're responsible for recording lawfully and for what "
                        + "you permit the AI agents to do; AI output can be wrong. "
                        + "The full terms:"
                )
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            ScrollView {
                MarkdownText(markdown: TermsAcceptance.text(), style: .answer)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            // The text view's intrinsic height settles after presentation, which
            // otherwise leaves the sheet opened scrolled near the document's end.
            .defaultScrollAnchor(.top)
            .background(Theme.surfaceCardInset)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            HStack {
                Button("Decline & Quit") { NSApp.terminate(nil) }
                    .focusEffectDisabled()
                Spacer()
                Button("Accept", action: onAccept)
                    .keyboardShortcut(.defaultAction)
                    .focusEffectDisabled()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: 600)
        .background(Theme.surfaceWindow)
    }
}
