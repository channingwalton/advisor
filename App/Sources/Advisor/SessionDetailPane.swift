import AppKit
import SwiftUI

/// The Answer panel's request in flight — an Ask or a Summarise on the saved
/// note — kept so it can be stopped.
private struct AnswerRequest {
    /// The sidecar request id.
    let id: String
    /// The question asked, to put back in the field if stopped; nil for a Summarise.
    let question: String?
}

/// A follow-up streaming into a saved card.
private struct SavedReply {
    /// The card's body with the follow-up turn so far.
    var body: String
    /// The sidecar request, so deleting the card can stop it.
    var requestId: String?
    /// Finished but couldn't be saved — kept on screen so it can be copied.
    var unsaved = false
}

/// A research card asked for on a saved transcript, while it streams.
private struct SavedResearch {
    var card: Card
    /// The transcript line it will be saved under, and the paragraph's block
    /// offset when it was asked — together they find the paragraph to show it
    /// under as other edits shift offsets.
    let anchor: NoteEdit.Anchor
    let paragraphOffset: Int
    /// The sidecar request, for Skip and Delete.
    let requestId: String
}

/// The right-hand detail: a selected session rendered like the live window —
/// header + meta, the cards it surfaced, the questions asked of it, and the full
/// transcript — with the ask bar kept (answers append to the note on disk).
struct SessionDetailPane: View {
    let file: SessionFile
    let detail: SessionDetail
    /// The tag library, for the Tags chip's autocomplete and pill colours.
    let library: [SavedTag]
    /// Which right-click research actions Preferences allows.
    let triggers: AdvisorConfig.Triggers
    /// The note as feed items and its card/note ids, built once per `detail`
    /// rather than on every redraw — streaming answers redraw many times a second.
    private let savedItems: [FeedItem]
    private let blockIds: [String?]

    init(file: SessionFile, detail: SessionDetail, library: [SavedTag], triggers: AdvisorConfig.Triggers) {
        self.file = file
        self.detail = detail
        self.library = library
        self.triggers = triggers
        savedItems = Feed.saved(blocks: detail.blocks, times: detail.blockTimes)
        blockIds = Feed.savedIds(detail.blocks)
    }

    @ObservedObject private var ctx = TranscriptWindowContext.shared

    // Ask state.
    @State private var question = ""
    @State private var answerBody = ""
    @State private var answerState = "" // "" idle, else pending|streaming|done|failed
    @State private var askNote = ""
    /// True while the in-flight `liveAnswer` is a summary rather than a Q&A, so its
    /// header reads "Summary" (issue #30). The Ask path clears it.
    @State private var summarising = false
    /// The Ask or Summarise in flight, so the panel's stop button can end it.
    @State private var answerRequest: AnswerRequest?

    /// Experiment: hide transcript paragraphs/headings so only cards show.
    @State private var hideTranscript = false
    /// Cards the user expanded or collapsed, by card id (`Feed.savedIds`, which
    /// follow the content); the rest keep their default (fact-checks collapsed).
    /// View state only, like the recording window's — it never touches the note.
    @State private var expansion: [String: Bool] = [:]
    /// Research cards asked for on this note's transcript, shown under their
    /// paragraph until the finished card is saved into the note.
    @State private var research: [SavedResearch] = []
    /// Follow-ups streaming into saved cards, by card id.
    @State private var replies: [String: SavedReply] = [:]

    // Rename state.
    @State private var renaming = false
    @State private var renameText = ""

    // Delete confirmation.
    @State private var confirmingDelete = false

    @State private var editingTags = false

    private var isAsking: Bool { answerState == "pending" || answerState == "streaming" }
    /// Asking the still-being-written live note is disabled (the writer's
    /// debounced rewrite would clobber an appended follow-up).
    private var isLive: Bool { file.url == ctx.liveFileURL }

    var body: some View {
        // A centred reading column; the ask field floats over the bottom of it,
        // with the content scrolling underneath.
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                if !detail.questions.isEmpty { youAsked }
                transcript
            }
            .frame(maxWidth: Theme.Metric.readingWidth, alignment: .leading)
            .padding(.horizontal, Theme.Metric.readingMargin)
            .padding(.top, 20)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .toolbar {
            // The detail's items otherwise sit at its leading edge, beside the
            // sidebar, where they're easy to miss; a flexible spacer pushes them
            // to the trailing edge, where the recording window keeps its controls.
            ToolbarSpacer(.flexible)
            ToolbarItemGroup {
                hideTranscriptButton
                summariseButton
                tagsButton
                moreMenu
            }
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail.title)
                .font(.system(size: 24, weight: .semibold))
                .kerning(-0.3)
                .foregroundStyle(Theme.textStrong)
                .fixedSize(horizontal: false, vertical: true)
            Text(metaLine).font(.system(size: 12.5)).monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
            tagRow
        }
        .alert("Rename session", isPresented: $renaming) {
            TextField("Session name", text: $renameText)
            Button("Save", action: saveName)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Give this session a name. Leave blank to fall back to its context.")
        }
        .alert("Delete session", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { deleteSession(file) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete “\(detail.title)”? This permanently removes its transcript "
                + "and cards, and can't be undone.")
        }
    }

    /// At-a-glance pills for the session's tags (library-known only), under the
    /// meta line. Editing is via the toolbar's Tags button.
    @ViewBuilder private var tagRow: some View {
        let known = detail.tags.compactMap { name in
            TagLibrary.named(name, in: library).map { (name, $0.colorHex) }
        }
        if !known.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(known, id: \.0) { name, hex in
                    TagPill(name: name, colorHex: hex)
                }
            }
            .padding(.top, 2)
        }
    }

    /// Toggle the transcript off so the detail shows only cards (experiment).
    private var hideTranscriptButton: some View {
        Button { hideTranscript.toggle() } label: {
            Label(
                hideTranscript ? "Show Transcript" : "Hide Transcript",
                systemImage: hideTranscript ? "eye.slash" : "eye")
        }
        .focusEffectDisabled()
        .help(hideTranscript ? "Show transcript" : "Hide transcript (cards only)")
    }

    /// Edit the session's tags in a popover anchored to the toolbar.
    private var tagsButton: some View {
        Button { editingTags.toggle() } label: {
            Label("Tags", systemImage: detail.tags.isEmpty ? "tag" : "tag.fill")
        }
        .focusEffectDisabled()
        .help("Session tags")
        .popover(isPresented: $editingTags, arrowEdge: .bottom) {
            SessionTagsEditor(tags: detail.tags, library: library, onChange: applyTags)
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Rename…") {
                renameText = detail.name
                renaming = true
            }
            Button("Export…") { exportSessionCopy(file) }
            ShareLink("Share…", item: file.url, preview: SharePreview(detail.title))
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            }
            Divider()
            // The live note is exempt: its writer would just recreate any
            // file deleted out from under it.
            Button("Delete…", role: .destructive) { confirmingDelete = true }
                .disabled(isLive)
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .focusEffectDisabled()
        .help("Rename, export, share or delete")
    }

    /// Add or update this session's Summary card (issue #30). Disabled while the
    /// note is still being recorded (its writer would clobber the upsert) or while
    /// an ask/summary is already streaming — mirrors the ask bar's gating.
    private var summariseButton: some View {
        Button(action: submitSummarise) {
            Label("Summarise", systemImage: "list.bullet.rectangle")
        }
        .focusEffectDisabled()
        .disabled(isLive || isAsking)
        .help(isLive
            ? "Summarise once the session has fully saved"
            : "Summarise this conversation (adds or updates a Summary card)")
    }

    /// Summarise the whole saved transcript into its single `# Summary` section,
    /// replacing any existing one. Streams into the answer strip, then persists on
    /// disk and refreshes the browser so the summary card shows.
    private func submitSummarise() {
        guard !isAsking, !isLive else { return }
        guard let sidecar = ctx.sidecar else { askNote = "Sidecar not running."; return }

        askNote = ""
        summarising = true
        answerBody = "…"
        answerState = "pending"
        let document = SessionArchive.contents(of: file)

        let sent = sidecar.summariseDocument(transcript: document) { body, state in
            answerBody = body
            answerState = state
            if !isAsking { answerRequest = nil }
            if state == "done" {
                // Issue #51: only clear and reload once the summary is on disk. On
                // failure keep it visible (leave answerBody / answerState) so it
                // isn't lost, and don't post — but still drop `summarising` so the
                // UI isn't stuck.
                if SessionArchive.save(to: file, { SessionArchive.upsertSummary(body, to: $0) }) {
                    NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
                    answerBody = ""
                    answerState = ""
                    summarising = false
                } else {
                    askNote = "Summary couldn't be saved to disk."
                    summarising = false
                }
            }
        }
        if let sent {
            answerRequest = AnswerRequest(id: sent, question: nil)
        } else {
            askNote = "Sidecar not running — summary not requested."
            answerBody = ""
            answerState = ""
            summarising = false
        }
    }

    /// Stop the Ask or Summarise in flight: the sidecar request is dropped (its
    /// handler too, so nothing late can save it), the panel closes, and an Ask's
    /// question goes back in the field (it is disabled while asking, so empty).
    /// Nothing reaches the note.
    private func cancelAnswer() {
        guard let request = answerRequest else { return }
        ctx.sidecar?.discardDocumentRequest(request.id)
        answerRequest = nil
        if let asked = request.question { question = asked }
        answerBody = ""
        answerState = ""
        summarising = false
        askNote = ""
    }

    /// Persist a tag change. The live/just-finished note is tagged through its
    /// writer (so a late card rewrite carries the tags); any other note is edited
    /// on disk directly. Either way, reload the browser from disk. Mirrors
    /// `saveName`.
    private func applyTags(_ tags: [String]) {
        if isLive, let writer = ctx.writer {
            writer.setOwnedNoteTags(tags)
            // Keep the recording window's own tag state in step, or its next
            // toolbar edit would overwrite this one from a stale array.
            NotificationCenter.default.post(
                name: .advisorLiveTagsChanged, object: nil, userInfo: ["tags": tags])
            NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
        } else if SessionArchive.setTags(tags, in: file) {
            NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
        } else {
            // Issue #51: the write failed — surface it and don't post the change
            // notification, which would reload from disk and show the OLD tags as
            // if nothing had changed.
            askNote = "Couldn't save tags to disk."
        }
    }

    /// Persist the renamed title via the shared, live-note-aware helper.
    private func saveName() { renameSession(file, to: renameText, ctx: ctx) }

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
        return parts.joined(separator: " · ")
    }

    // MARK: you asked

    private var youAsked: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeedSectionLabel(
                title: "You asked",
                count: detail.questions.count == 1 ? "1 question" : "\(detail.questions.count) questions")
            ForEach(Array(detail.questions.enumerated()), id: \.offset) { _, q in
                HStack(alignment: .top, spacing: 10) {
                    Text("Y").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(Theme.fieldFill, in: Circle())
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

    /// The saved note in the shared feed — the same rows and controls as the
    /// recording window, with this note's actions.
    private var transcript: some View {
        VStack(alignment: .leading, spacing: FeedView.spacing) {
            FeedSectionLabel(title: hideTranscript ? "Cards" : "Transcript")
            FeedView(
                items: Feed.mapCards(Feed.applyingExpansion(
                    expansion,
                    to: Feed.grouped(
                        Feed.inserting(
                            research.map { pending in
                                let paragraph = NoteEdit.paragraphOffset(
                                    endingWith: pending.anchor.line, near: pending.paragraphOffset,
                                    in: detail.blocks)
                                return (afterParagraph: paragraph.map(String.init) ?? "", card: pending.card)
                            },
                            into: savedItems),
                        hideTranscript: hideTranscript))) { card in
                    if let reply = replies[card.id] {
                        card.body = reply.body
                        card.state = reply.unsaved ? "done" : "streaming"
                        card.replying = true
                    }
                    // A finished research card that couldn't be saved has no place
                    // in the note to take a follow-up.
                    if card.state == "done", research.contains(where: { $0.card.id == card.id }) {
                        card.replying = true
                    }
                },
                actions: feedActions)
        }
    }

    /// What a saved note allows. The live note is still owned by its writer, so
    /// edits here would be clobbered — it stays read-only until saved (collapse
    /// is view state, so it's always allowed).
    private var feedActions: FeedActions {
        FeedActions(
            transcriptActions: isLive ? [] : TranscriptAction.research(for: triggers),
            onAction: { kind, selection, paragraph in startResearch(kind, on: selection, in: paragraph) },
            onAddNote: isLive
                ? nil
                : { text, offset, paragraph in
                    guard let block = Int(paragraph.id) else { return }
                    finishEdit(SessionArchive.insertNote(
                        text, inParagraphAt: block, expecting: detail.blocks[block], atCharacter: offset,
                        in: file))
                },
            onCorrect: isLive
                ? nil
                : { request, paragraph in
                    // Saved paragraph ids are their block offsets.
                    guard let offset = Int(paragraph.id) else { return }
                    apply(request, toParagraph: paragraphOrdinal(before: offset))
                },
            onToggleCard: { card in expansion[card.id] = !card.isExpanded },
            onDeleteCard: isLive ? nil : { card in deleteBlock(id: card.id) },
            onCancelCard: { card in
                // Skip: drop the handler too, so a finish already on its way can't
                // save the card; it stays, marked skipped, until deleted.
                guard let index = research.firstIndex(where: { $0.card.id == card.id }) else { return }
                ctx.sidecar?.discardDocumentRequest(research[index].requestId)
                research[index].card.state = "cancelled"
            },
            onReply: isLive ? nil : { card, question in startReply(on: card, question) },
            onDeleteNote: isLive ? nil : { id in deleteBlock(id: id) })
    }

    /// Remove a card or note from the note on disk — or, for a research card not
    /// saved yet, stop it and drop it.
    private func deleteBlock(id: String) {
        if let pending = research.first(where: { $0.card.id == id }) {
            // Drop its handler too, so a finish already on its way can't save it.
            ctx.sidecar?.discardDocumentRequest(pending.requestId)
            research.removeAll { $0.card.id == id }
            return
        }
        // A follow-up still streaming into this card has nowhere to go now.
        if let reply = replies.removeValue(forKey: id), let request = reply.requestId {
            ctx.sidecar?.discardDocumentRequest(request)
        }
        guard let offset = blockIds.firstIndex(of: id) else { return }
        finishEdit(SessionArchive.removeBlock(at: offset, expecting: detail.blocks[offset], from: file))
    }

    /// Research `selection` from the paragraph it's in (right-click Answer /
    /// Context / Fact check). The card streams in under the paragraph and, once
    /// done, is saved into the note under the paragraph's last line — where the
    /// live feed anchors a manual card. A failed or skipped card stays until
    /// deleted, and isn't saved.
    private func startResearch(_ kind: String, on selection: String, in paragraph: FeedParagraph) {
        guard let offset = Int(paragraph.id), detail.blocks.indices.contains(offset) else { return }
        guard let sidecar = ctx.sidecar else { askNote = "Sidecar not running."; return }
        let document = SessionArchive.contents(of: file)
        guard let anchor = NoteEdit.anchor(ofParagraphAt: offset, expecting: detail.blocks[offset], in: document)
        else { return finishEdit(false) }

        let card = Card(
            id: "research-\(UUID().uuidString)", created: Date(), kind: kind, title: selection,
            body: "…", state: "pending",
            footnote: kind == "answer" ? SavedCard.savedGroundedNote : nil,
            isExpanded: kind != "factcheck")
        let file = file
        let request = sidecar.researchDocument(action: kind, text: selection, document: document) { body, state in
            // Save first, from captured values: the user may have moved to another
            // session, taking this pane's state with it.
            if state == "done" {
                var done = card
                done.body = body
                done.state = state
                if SessionArchive.save(to: file, { SessionArchive.insertBlock(SessionMarkdown.cardBlock(done), after: anchor, in: $0) }) {
                    research.removeAll { $0.card.id == card.id }
                    NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
                    return
                }
                // Only an unreadable note or a failed write gets here.
                askNote = "Couldn't save the card to the note — copy it before navigating away."
            }
            guard let index = research.firstIndex(where: { $0.card.id == card.id }) else { return }
            research[index].card.body = body
            research[index].card.state = state
        }
        guard let request else { askNote = "Sidecar not running — not sent."; return }
        research.append(SavedResearch(card: card, anchor: anchor, paragraphOffset: offset, requestId: request))
    }

    /// Ask a follow-up on a saved card. The answer streams into the card in the
    /// live turn format and, once done, the card's body is rewritten in the note.
    /// A failed or skipped follow-up leaves the note as it was.
    private func startReply(on card: Card, _ question: String) {
        guard replies[card.id] == nil else { return }
        guard let sidecar = ctx.sidecar else { askNote = "Sidecar not running."; return }
        let base = card.body
        let file = file
        let request = sidecar.replyDocument(
            kind: card.kind, title: card.title, base: base, replyText: question,
            document: SessionArchive.contents(of: file)
        ) { answer, state in
            let body = SessionMarkdown.replyBody(base: base, question: question, answer: answer)
            switch state {
            case "done":
                // Save first, from captured values: the user may have moved on.
                if SessionArchive.save(to: file, { SessionArchive.replaceCardBody(ofCard: card.id, body: base, with: body, in: $0) }) {
                    replies[card.id] = nil
                    // The new body gives the card a new id; keep it open, as it
                    // was to take the follow-up (a fact-check would otherwise shut).
                    let saved = SessionArchive.relocated(file) ?? file
                    if let newId = NoteEdit.cardId(withBody: body, in: SessionArchive.contents(of: saved)) {
                        expansion[newId] = true
                    }
                    NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
                } else {
                    replies[card.id]?.body = body
                    replies[card.id]?.unsaved = true
                    askNote = "Couldn't save the follow-up to the note — copy it before navigating away."
                }
            case "failed":
                replies[card.id] = nil
                askNote = "The follow-up didn't complete — \(answer)"
            case "cancelled":
                replies[card.id] = nil
            default:
                replies[card.id]?.body = body
            }
        }
        guard let request else { askNote = "Sidecar not running — follow-up not sent."; return }
        replies[card.id] = SavedReply(
            body: SessionMarkdown.replyBody(base: base, question: question, answer: "…"), requestId: request)
    }

    /// After an edit to the note on disk, refresh the list cache (and so this
    /// pane's `detail`) either way: an edit that didn't apply usually means the
    /// note changed underneath us, so the reload shows what's there now.
    private func finishEdit(_ applied: Bool) {
        if !applied {
            askNote = Self.editFailed
        } else if askNote == Self.editFailed {
            askNote = ""
        }
        NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
    }

    private static let editFailed = "Couldn't update the note — it may have changed on disk, so it has been reloaded."

    /// The 0-based index of the paragraph at block `offset` among paragraph blocks
    /// only — the index `TranscriptCorrection` keys on (it groups paragraphs the
    /// same way `TranscriptDoc` does, skipping cards and headings) (issue #32).
    private func paragraphOrdinal(before offset: Int) -> Int {
        detail.blocks[..<offset].reduce(0) {
            if case .paragraph = $1 { return $0 + 1 }
            return $0
        }
    }

    /// Apply a transcription correction to the saved note on disk, then refresh
    /// the parent list cache (and so this pane's `detail`) so the edit shows.
    private func apply(_ request: TranscriptCorrectionRequest, toParagraph paragraphIndex: Int) {
        let changed: Bool
        switch request.scope {
        case .thisOccurrence:
            changed = SessionArchive.correctOccurrence(
                request.occurrenceInParagraph, of: request.original, with: request.replacement,
                inParagraph: paragraphIndex, of: file)
        case .allInSession:
            changed = SessionArchive.correctAll(
                of: request.original, with: request.replacement, in: file)
        }
        if changed { NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil) }
    }

    // MARK: ask

    /// The streaming answer (or summary) card, the ask field, and any error,
    /// floating over the bottom of the reading column. The page fades out under
    /// it so scrolled text doesn't collide with the field.
    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            // While running, even before any text, so Stop is always there.
            if isAsking || !answerBody.isEmpty { liveAnswer }
            askField
            if !askNote.isEmpty {
                Text(askNote).font(.system(size: 11.5)).foregroundStyle(Theme.factRed)
                    .padding(.leading, 18)
            }
        }
        .frame(maxWidth: Theme.Metric.readingWidth)
        .padding(.horizontal, Theme.Metric.readingMargin)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                stops: [
                    .init(color: Theme.surfaceWindow.opacity(0), location: 0),
                    .init(color: Theme.surfaceWindow, location: 0.45),
                ],
                startPoint: .top, endPoint: .bottom))
    }

    private var liveAnswer: some View {
        AnswerPanel(
            title: answerState == "failed"
                ? (summarising ? "Couldn't summarise" : "Couldn't answer")
                : (summarising ? "Summary" : "Answer"),
            titleColor: answerState == "failed"
                ? Theme.factRed
                : (summarising ? Theme.summaryTeal : Theme.accent),
            markdown: answerBody,
            isRunning: isAsking,
            stop: answerRequest == nil ? nil : cancelAnswer,
            stopHelp: summarising ? "Stop summarising" : "Stop answering")
    }

    private var canAsk: Bool {
        !isLive && !isAsking && !question.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// One rounded glass field with an inline send arrow that takes the accent
    /// once there's a question to send.
    private var askField: some View {
        HStack(spacing: 8) {
            TextField(
                isLive
                    ? "Advisor is still writing this session — ask once it has fully saved"
                    : "Ask about this session",
                text: $question)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .onSubmit(submitQuestion)
                .disabled(isLive || isAsking)
            Button(action: submitQuestion) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(canAsk ? Theme.onAccent : Theme.textTertiary)
                    .frame(width: 28, height: 28)
                    .background(canAsk ? Theme.accent : Theme.fieldFill, in: Circle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(!canAsk)
            .help("Ask (↩)")
        }
        .padding(.leading, 18)
        .padding(.trailing, 7)
        .frame(height: 42)
        .glassEffect(.regular, in: Capsule())
    }

    private func submitQuestion() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isAsking, !isLive else { return }
        guard let sidecar = ctx.sidecar else { askNote = "Sidecar not running."; return }

        askNote = ""
        summarising = false
        answerBody = "…"
        answerState = "pending"
        let document = SessionArchive.contents(of: file)

        let sent = sidecar.askDocument(question: q, document: document) { body, state in
            answerBody = body
            answerState = state
            if !isAsking { answerRequest = nil }
            if state == "done" {
                // Issue #51: only clear the answer and reload once the append is
                // on disk. On failure keep the answer visible (leave answerBody /
                // answerState as they are) so the Q&A isn't lost, and don't post —
                // a reload would drop the unsaved answer.
                if SessionArchive.save(to: file, { SessionArchive.appendFollowUp(question: q, answer: body, to: $0) }) {
                    // Refresh the parent list cache (and so this pane's `detail`),
                    // not just a pane-local copy, or the appended Q&A would vanish on
                    // navigating away and back or via search.
                    NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
                    answerBody = ""
                    answerState = ""
                } else {
                    askNote = "Answer couldn't be saved to disk — copy it before navigating away."
                }
            }
        }
        guard let sent else {
            askNote = "Sidecar not running — question not sent."
            answerBody = ""
            answerState = ""
            return
        }
        answerRequest = AnswerRequest(id: sent, question: q)
        question = ""
    }
}
