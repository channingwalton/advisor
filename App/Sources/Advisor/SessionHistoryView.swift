import MarkdownUI
import SwiftUI

/// Browse and read past session notes, and ask questions about the selected one.
/// A master/detail sheet: the saved sessions on the left (newest first), the
/// transcript on the right with an ask bar. An answer streams in below the
/// transcript and, when finished, is appended to the note on disk (under a
/// `# Follow-ups` heading) so the transcript grows with the questions asked.
struct SessionHistoryView: View {
    /// Used to answer questions about the selected transcript. Nil-safe: the ask
    /// bar reports if the sidecar is down.
    let sidecar: SidecarManager?
    /// The note the live `SessionWriter` still owns (set from session start until
    /// the next session starts), if any. Asking about it is disabled: the
    /// writer's debounced full rewrite — which still fires post-stop as late
    /// research cards finish — would clobber an appended follow-up.
    let liveFileURL: URL?

    @Environment(\.dismiss) private var dismiss
    @State private var files: [SessionFile] = []
    @State private var selected: SessionFile?
    @State private var contents = ""

    // Ask state.
    @State private var question = ""
    /// The session being asked about while an answer streams (may differ from
    /// `selected` if the user switches mid-answer); gates the live-answer view.
    @State private var askingFile: SessionFile?
    @State private var answerBody = ""
    @State private var answerState = "" // "" idle, else pending|streaming|done|failed
    @State private var askNote = ""

    private var isAsking: Bool { answerState == "pending" || answerState == "streaming" }
    private var selectedIsLive: Bool { selected != nil && selected?.url == liveFileURL }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            HSplitView {
                sessionList
                    .frame(minWidth: 220, idealWidth: 240, maxWidth: 320)
                detail
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(Theme.surfaceWindow)
        .onAppear(perform: reload)
    }

    // MARK: header

    private var headerBar: some View {
        HStack {
            Text("Previous transcripts")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textStrong)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .frame(height: Theme.Metric.toolbarHeight)
        .background(Theme.surfaceTitlebar)
    }

    // MARK: list

    private var sessionList: some View {
        Group {
            if files.isEmpty {
                Text("No previous sessions yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                List(files, selection: $selected) { file in
                    Text(Self.rowLabel(file.date))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textBody)
                        .padding(.vertical, 2)
                        .tag(file)
                }
                .listStyle(.sidebar)
            }
        }
        .onChange(of: selected) { _, file in
            contents = file.map(SessionArchive.contents) ?? ""
        }
    }

    /// e.g. "Thu 18 Jun 2026, 16:39".
    private static func rowLabel(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()
            .hour().minute())
    }

    // MARK: detail

    @ViewBuilder private var detail: some View {
        if selected == nil {
            Text("Select a session to read it.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                transcriptScroll
                if !answerBody.isEmpty && askingFile == selected {
                    Divider()
                    liveAnswer
                }
                Divider()
                askBar
            }
        }
    }

    private var transcriptScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if let date = selected?.date {
                    Text(Self.rowLabel(date))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                }
                Markdown(SessionArchive.strippingFrontmatter(contents))
                    .textSelection(.enabled)
                    .markdownTextStyle(\.text) {
                        FontSize(Theme.Metric.transcriptSize)
                        ForegroundColor(Theme.textBody)
                    }
                    .markdownTextStyle(\.link) { ForegroundColor(Theme.accent) }
                    .markdownBlockStyle(\.heading1) { config in
                        config.label
                            .markdownMargin(top: 16, bottom: 6)
                            .markdownTextStyle {
                                FontWeight(.semibold)
                                FontSize(17)
                                ForegroundColor(Theme.textStrong)
                            }
                    }
                    .markdownBlockStyle(\.heading2) { config in
                        config.label
                            .markdownMargin(top: 12, bottom: 4)
                            .markdownTextStyle {
                                FontWeight(.semibold)
                                FontSize(14)
                                ForegroundColor(Theme.textStrong)
                            }
                    }
            }
            .frame(maxWidth: Theme.Metric.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Metric.contentSidePad)
            .padding(.vertical, Theme.Metric.contentTopPad)
        }
        .frame(maxHeight: .infinity)
    }

    /// The streaming answer, shown until it's appended to the note (on "done")
    /// or it fails. A small inline card mirroring the answer-card style.
    private var liveAnswer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if isAsking { ProgressView().controlSize(.small).scaleEffect(0.7) }
                    Text(answerState == "failed" ? "Couldn't answer" : "Answer")
                        .font(.system(size: 11, weight: .bold)).kerning(0.5)
                        .foregroundStyle(answerState == "failed" ? Theme.factRed : Theme.accent)
                }
                Markdown(answerBody)
                    .textSelection(.enabled)
                    .markdownTextStyle(\.text) {
                        FontSize(Theme.Metric.cardBodySize)
                        ForegroundColor(Theme.textBody)
                    }
                    .markdownTextStyle(\.link) { ForegroundColor(Theme.accent) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .frame(maxHeight: 200)
        .background(Theme.surfaceCard)
    }

    private var askBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                TextField(
                    selectedIsLive
                        ? "Advisor is still writing this session — ask once it has fully saved…"
                        : "Ask a question about this transcript…",
                    text: $question)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Theme.surfaceCardInset, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 0.5))
                    .onSubmit(submitQuestion)
                    .disabled(selectedIsLive || isAsking)
                Button("Ask", action: submitQuestion)
                    .buttonStyle(SendButtonStyle(accent: Theme.accent))
                    .disabled(selectedIsLive || isAsking
                        || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !askNote.isEmpty {
                Text(askNote).font(.system(size: 11)).foregroundStyle(Theme.factRed)
            }
        }
        .padding(.horizontal, Theme.Metric.contentSidePad)
        .padding(.vertical, 10)
        .background(Theme.surfaceTitlebar)
    }

    // MARK: actions

    private func submitQuestion() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isAsking, let file = selected, !selectedIsLive else { return }
        guard let sidecar else { askNote = "Sidecar not running."; return }

        askNote = ""
        askingFile = file
        answerBody = "…"
        answerState = "pending"
        let document = SessionArchive.contents(of: file)

        let sent = sidecar.askDocument(question: q, document: document) { body, state in
            answerBody = body
            answerState = state
            switch state {
            case "done":
                // Persist the Q&A to the note, then refresh the view from disk so
                // the appended block shows in the transcript; clear the transient.
                SessionArchive.appendFollowUp(question: q, answer: body, to: file)
                if selected == file { contents = SessionArchive.contents(of: file) }
                answerBody = ""
                answerState = ""
            case "failed", "cancelled":
                break // leave answerBody showing the error
            default:
                break
            }
        }
        if sent == nil {
            askNote = "Sidecar not running — question not sent."
            answerBody = ""
            answerState = ""
            askingFile = nil
            return
        }
        question = ""
    }

    private func reload() {
        files = SessionArchive.list()
        if selected == nil { selected = files.first }
        contents = selected.map(SessionArchive.contents) ?? ""
    }
}
