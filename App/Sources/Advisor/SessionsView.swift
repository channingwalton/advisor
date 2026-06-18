import AppKit
import MarkdownUI
import SwiftUI

/// A saved session paired with its parsed detail, the unit the browser lists.
private struct LoadedSession: Identifiable, Equatable {
    let file: SessionFile
    let detail: SessionDetail
    var id: URL { file.url }

    /// Lowercased haystack for search (title, gist, transcript, card titles).
    let haystack: String
}

/// The Sessions browser: a master/detail window over saved session notes. Left:
/// search + filters + a date-grouped list. Right: the selected session rendered
/// like the live window (header, cards surfaced, questions asked, transcript)
/// with the ask bar kept. Replaces the old picker + per-session windows.
///
/// Scope is "layout + real data": everything here comes from the saved notes.
/// The handoff's AI-derived bits (category badge, topic chips, summary, people,
/// action items) and star/Resume are deliberately not rendered yet.
struct SessionsView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var sessions: [LoadedSession] = []
    @State private var selection: URL?
    @State private var query = ""
    @State private var thisWeekOnly = false
    @State private var oldestFirst = false

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 350)
                    .background(Theme.surfaceTitlebar)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.surfaceWindow)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(Theme.surfaceWindow)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .advisorSessionsChanged)) { _ in
            reload()
        }
        // When a filter hides the selected session, select the first visible one
        // so the detail and sidebar stay consistent.
        .onChange(of: query) { _, _ in reconcileSelection() }
        .onChange(of: thisWeekOnly) { _, _ in reconcileSelection() }
    }

    private func reconcileSelection() {
        if !filtered.contains(where: { $0.id == selection }) {
            selection = filtered.first?.id
        }
    }

    // MARK: title bar

    private var titleBar: some View {
        HStack(spacing: 6) {
            Text("Advisor").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textStrong)
            Text("·").foregroundStyle(Theme.textMuted)
            Text("Sessions").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        // Title stays centred; "New" opens the single recording window (or brings
        // the existing one forward).
        .overlay(alignment: .trailing) {
            Button { openWindow(id: "recording") } label: {
                Label("New", systemImage: "plus")
            }
            .help("Start a new recording")
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(Theme.surfaceTitlebar)
    }

    // MARK: sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                searchField
                filterRow
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                    if grouped.isEmpty {
                        Text(query.isEmpty ? "No previous sessions yet." : "No matches.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.top, 16)
                    }
                    ForEach(grouped, id: \.label) { group in
                        Section {
                            ForEach(group.sessions) { session in
                                sessionRow(session)
                            }
                        } header: {
                            Text(group.label)
                                .font(.system(size: 10.5, weight: .bold)).kerning(0.4)
                                .foregroundStyle(Theme.textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.top, 14).padding(.bottom, 4)
                                .background(Theme.surfaceTitlebar)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            TextField("Search sessions, people, topics…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Theme.surfaceCard, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline, lineWidth: 0.5))
    }

    private var filterRow: some View {
        HStack(spacing: 6) {
            chip("All", on: !thisWeekOnly) { thisWeekOnly = false }
            chip("This week", on: thisWeekOnly) { thisWeekOnly = true }
            Spacer()
            Button { oldestFirst.toggle() } label: {
                HStack(spacing: 3) {
                    Text(oldestFirst ? "Oldest" : "Recent").font(.system(size: 11.5))
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Sort order")
        }
    }

    private func chip(_ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 11.5, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.white : Theme.textBody)
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(
                    on ? Theme.accent : Theme.surfaceCard,
                    in: Capsule())
                .overlay(Capsule().stroke(on ? .clear : Theme.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private func sessionRow(_ session: LoadedSession) -> some View {
        let selected = selection == session.id
        let d = session.detail
        return Button { selection = session.id } label: {
            HStack(alignment: .top, spacing: 9) {
                Circle().fill(Theme.accent).frame(width: 7, height: 7).padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(d.title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Theme.textStrong)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(Self.rowTime(d.started ?? session.file.date))
                            .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    }
                    if !d.gist.isEmpty {
                        Text(d.gist).font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        if let m = d.durationMinutes {
                            Text("\(m) min").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                        }
                        HStack(spacing: 4) {
                            Circle().fill(Theme.accent).frame(width: 4, height: 4)
                            Text("\(d.cards.count) cards").font(.system(size: 11))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 11)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Theme.surfaceCard : .clear)
                    .shadow(color: selected ? Theme.cardShadow : .clear, radius: 4, y: 1))
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.accent)
                        .frame(width: 3).padding(.vertical, 4)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Theme.accent.opacity(0.22) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    // MARK: detail

    @ViewBuilder private var detail: some View {
        // Resolve against the *filtered* list: a session hidden by search/filter
        // must not stay open in the detail (the Ask bar would append to a
        // transcript no longer in the sidebar).
        if let selected = filtered.first(where: { $0.id == selection }) {
            SessionDetailPane(file: selected.file, detail: selected.detail)
                .id(selected.id)
        } else {
            Text("Select a session to read it.")
                .font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: data

    private func reload() {
        sessions = SessionArchive.list().map { file in
            let contents = SessionArchive.contents(of: file)
            let detail = SessionDetail.parse(
                contents: contents, fallbackTitle: Self.rowTitle(file.date))
            let haystack = ([detail.title, detail.name, detail.context, detail.gist]
                + detail.cards.map(\.title)
                + detail.blocks.compactMap { if case .paragraph(let t) = $0 { t } else { nil } })
                .joined(separator: " ").lowercased()
            return LoadedSession(file: file, detail: detail, haystack: haystack)
        }
        if selection == nil || !sessions.contains(where: { $0.id == selection }) {
            selection = filtered.first?.id
        }
    }

    /// Filtered + sorted sessions (search + this-week chip + sort order).
    private var filtered: [LoadedSession] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let cal = Calendar.current
        return sessions
            .filter { q.isEmpty || $0.haystack.contains(q) }
            // Calendar week, matching the sidebar's TODAY / YESTERDAY / EARLIER
            // THIS WEEK grouping — not a rolling 7 days, which would disagree
            // with those labels near the start of the week.
            .filter {
                !thisWeekOnly
                    || cal.isDate($0.detail.started ?? $0.file.date, equalTo: Date(),
                        toGranularity: .weekOfYear)
            }
            .sorted {
                let a = $0.detail.started ?? $0.file.date
                let b = $1.detail.started ?? $1.file.date
                return oldestFirst ? a < b : a > b
            }
    }

    /// Filtered sessions grouped into relative-date sections, in list order.
    private var grouped: [(label: String, sessions: [LoadedSession])] {
        var order: [String] = []
        var byLabel: [String: [LoadedSession]] = [:]
        for session in filtered {
            let label = Self.bucket(session.detail.started ?? session.file.date)
            if byLabel[label] == nil { order.append(label) }
            byLabel[label, default: []].append(session)
        }
        return order.map { ($0, byLabel[$0] ?? []) }
    }

    // MARK: date formatting

    private static func bucket(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "TODAY" }
        if cal.isDateInYesterday(date) { return "YESTERDAY" }
        let now = Date()
        if cal.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return "EARLIER THIS WEEK" }
        if cal.isDate(date, equalTo: now, toGranularity: .month) { return "THIS MONTH" }
        return "EARLIER"
    }

    /// Right-aligned row time: today → time, this week → weekday, else date.
    private static func rowTime(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if cal.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// Fallback title (no context in the note): date + time.
    private static func rowTitle(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}

/// The right-hand detail: a selected session rendered like the live window —
/// header + meta, the cards it surfaced, the questions asked of it, and the full
/// transcript — with the ask bar kept (answers append to the note on disk).
private struct SessionDetailPane: View {
    let file: SessionFile
    let detail: SessionDetail

    @ObservedObject private var ctx = TranscriptWindowContext.shared

    // Ask state.
    @State private var question = ""
    @State private var answerBody = ""
    @State private var answerState = "" // "" idle, else pending|streaming|done|failed
    @State private var askNote = ""

    // Rename state.
    @State private var renaming = false
    @State private var renameText = ""

    private var isAsking: Bool { answerState == "pending" || answerState == "streaming" }
    /// Asking the still-being-written live note is disabled (the writer's
    /// debounced rewrite would clobber an appended follow-up).
    private var isLive: Bool { file.url == ctx.liveFileURL }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if !detail.questions.isEmpty { youAsked }
                    transcript
                }
                .frame(maxWidth: Theme.Metric.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.vertical, 26)
            }
            if !answerBody.isEmpty {
                Divider()
                liveAnswer
            }
            Divider()
            askBar
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(detail.title)
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(Theme.textStrong)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Menu {
                    Button("Rename…") {
                        renameText = detail.name
                        renaming = true
                    }
                    Button("Export…", action: exportSession)
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([file.url])
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 30)
                        .background(Theme.surfaceCard, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline, lineWidth: 0.5))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            Text(metaLine).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
        }
        .alert("Rename session", isPresented: $renaming) {
            TextField("Session name", text: $renameText)
            Button("Save", action: saveName)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Give this session a name. Leave blank to fall back to its context.")
        }
    }

    /// Persist the renamed title. The live/just-finished note is renamed through
    /// its writer (so the rewrite carries the name); any other note is edited on
    /// disk directly. Either way, reload the browser from disk.
    private func saveName() {
        let new = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if isLive, let writer = ctx.writer {
            writer.renameOwnedNote(new)
        } else {
            SessionArchive.setName(new, in: file)
        }
        NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
    }

    private var metaLine: String {
        var parts: [String] = []
        if let started = detail.started {
            let day = started.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            if let ended = detail.ended {
                let from = started.formatted(date: .omitted, time: .shortened)
                let to = ended.formatted(date: .omitted, time: .shortened)
                parts.append("\(day) · \(from)–\(to)")
            } else {
                parts.append("\(day) · \(started.formatted(date: .omitted, time: .shortened))")
            }
        }
        if let m = detail.durationMinutes { parts.append("\(m) min") }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: you asked

    private var youAsked: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("YOU ASKED", count: "\(detail.questions.count) questions")
            ForEach(Array(detail.questions.enumerated()), id: \.offset) { _, q in
                HStack(alignment: .top, spacing: 10) {
                    Text("Y").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Theme.accent, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(q.question).font(.system(size: 13)).foregroundStyle(Theme.textBody)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(q.askedAt.isEmpty ? "Answered inline" : "Answered inline · \(q.askedAt)")
                            .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
    }

    // MARK: transcript

    private var transcript: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.paragraphSpacing) {
            sectionLabel("TRANSCRIPT", count: nil)
            ForEach(Array(detail.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    SelectableTranscriptText(
                        text: text, toolTip: "", actions: [], onAction: { _, _ in })
                case .card(let markdown):
                    cardBlock(markdown)
                case .heading(let title) where title != "Transcript":
                    Text(title).font(.system(size: 11, weight: .semibold)).kerning(0.5)
                        .foregroundStyle(Theme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                case .heading:
                    EmptyView()
                }
            }
        }
    }

    private func cardBlock(_ markdown: String) -> some View {
        Markdown(markdown)
            .textSelection(.enabled)
            .markdownTextStyle(\.text) {
                FontSize(Theme.Metric.cardBodySize)
                ForegroundColor(Theme.textBody)
            }
            .markdownTextStyle(\.link) { ForegroundColor(Theme.accent) }
            .markdownTextStyle(\.emphasis) { ForegroundColor(Theme.textMuted) }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.surfaceCard, in: RoundedRectangle(cornerRadius: Theme.Metric.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metric.cardRadius)
                    .stroke(Theme.hairline, lineWidth: 0.5))
            .padding(.vertical, 4)
    }

    // MARK: shared bits

    private func sectionLabel(_ title: String, count: String?) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11, weight: .bold)).kerning(0.5)
                .foregroundStyle(Theme.textSecondary)
            if let count {
                Text(count).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }
        }
    }

    // MARK: ask

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
                    isLive
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
                    .disabled(isLive || isAsking)
                Button("Ask", action: submitQuestion)
                    .buttonStyle(SendButtonStyle(accent: Theme.accent))
                    .disabled(isLive || isAsking
                        || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !askNote.isEmpty {
                Text(askNote).font(.system(size: 11)).foregroundStyle(Theme.factRed)
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 10)
        .background(Theme.surfaceTitlebar)
    }

    private func submitQuestion() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isAsking, !isLive else { return }
        guard let sidecar = ctx.sidecar else { askNote = "Sidecar not running."; return }

        askNote = ""
        answerBody = "…"
        answerState = "pending"
        let document = SessionArchive.contents(of: file)

        let sent = sidecar.askDocument(question: q, document: document) { body, state in
            answerBody = body
            answerState = state
            if state == "done" {
                SessionArchive.appendFollowUp(question: q, answer: body, to: file)
                // Refresh the parent list cache (and so this pane's `detail`),
                // not just a pane-local copy, or the appended Q&A would vanish on
                // navigating away and back or via search.
                NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
                answerBody = ""
                answerState = ""
            }
        }
        if sent == nil {
            askNote = "Sidecar not running — question not sent."
            answerBody = ""
            answerState = ""
            return
        }
        question = ""
    }

    private func exportSession() {
        let panel = NSSavePanel()
        panel.title = "Export Session"
        panel.nameFieldStringValue = file.url.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            // Atomic write (read source, then replace) — never pre-deletes the
            // destination, so a failure can't leave a chosen file gone, and
            // exporting onto the source itself is harmless.
            try Data(contentsOf: file.url).write(to: dest, options: .atomic)
        } catch {
            askNote = "Export failed: \(error.localizedDescription)"
        }
    }
}
