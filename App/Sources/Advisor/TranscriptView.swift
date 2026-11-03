import AppKit
import SwiftUI

struct TranscriptView: View {
    /// Launch-lifetime services (store, sidecar, writer) shared with the Sessions
    /// window. The recording window owns only the `Recorder` it builds on appear.
    let services: AppServices
    @ObservedObject var store: TranscriptStore
    @State private var recorder: Recorder?
    @State private var fatalError: String?
    @State private var devices: [InputDevice] = []
    @State private var selectedDevice: InputDevice?
    @AppStorage("captureSystem") private var captureSystem = true
    /// The Ask popover's question and the Note popover's draft (issue #104), kept
    /// while their popovers are closed, and whether each is open.
    @State private var queryText = ""
    @State private var showAsk = false
    @State private var noteDraft = NoteDraft()
    @State private var showNote = false
    /// True from the instant Summarise is tapped until the summary card reaches a
    /// terminal state. Guards the gap before the card returns, so a fast
    /// double-click can't spawn a second summary card (issue #30).
    @State private var summarisingLive = false

    init(services: AppServices) {
        self.services = services
        _store = ObservedObject(wrappedValue: services.store)
        _recordingControl = StateObject(wrappedValue: RecordingControl(store: services.store))
    }
    /// The session prompt: optional free-text context. Filled before Listen
    /// (sent on session_start) or edited live during the session (pushed via
    /// onChange). Cleared when the session stops.
    @State private var recordingDraft = RecordingDraft()
    /// The optional session name: a short label, distinct from the research
    /// context. Filled before Listen (seeded into the writer at start) or edited
    /// live; titles the session in the browser. Cleared when the session stops.
    @State private var sessionName = ""
    /// The session's tags (issue #15). Staged before Listen (seeded into the
    /// writer at start) or edited live via the toolbar's Tags chip; rendered as
    /// coloured pills in the browser. Cleared when the session stops.
    /// The user's tag library, for the toolbar's Tags chip autocomplete. Kept in
    /// sync with Preferences via `advisorConfigChanged`.
    @State private var tagLibrary: [SavedTag] = []
    @State private var triggers = AdvisorConfig.Triggers()
    /// The user's library of named, reusable contexts (issue #10) — loaded into
    /// the Context popover's Load menu. Kept in sync with Preferences via
    /// `advisorConfigChanged`; the popover's Save persists back to config.json.
    @State private var savedContexts: [SavedContext] = []
    @State private var autoCards = true
    /// Experiment: hide transcript paragraphs (and the interim line) so the feed
    /// shows only cards. Per-window UI state, not persisted.
    @State private var hideTranscript = false
    @State private var transcriptAutoScroll = TranscriptAutoScroll()
    @State private var pinned = false
    /// When the current session started — drives the toolbar timer. Non-nil for
    /// the whole session (Listen until the window closes), even while stopped.
    /// Shifted forward by each stop's duration so the timer excludes stops.
    @StateObject private var recordingControl: RecordingControl
    private var sessionStart: Date? { recordingControl.sessionStart }
    /// When stopped, the moment of stopping — freezes the timer and marks the
    /// session resumable. Nil while recording or idle.
    private var stoppedAt: Date? { recordingControl.stoppedAt }
    @State private var spaceMonitor: Any?
    /// The recording window, for the Space key monitor (issue #111), the feed's
    /// field check and Float on Top (issue #123).
    @State private var hostWindow = HostWindow()
    /// True while a "Wait"-to-close is draining the session's in-flight agents.
    /// Covers the window with a blocking overlay so the about-to-close UI can't
    /// be driven (e.g. Space starting a fresh session). Cleared by the close.
    @State private var finishing = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("agentLanes") private var agentLanes = 3
    @AppStorage("micDeviceName") private var micDeviceName = ""
    /// Shared window context, observed for the pending folder target (issue #35) a
    /// folder's record button sets before this window opens.
    @ObservedObject private var winCtx = TranscriptWindowContext.shared
    /// The folder this session is being recorded into (issue #35), captured from
    /// `winCtx.pendingFolder` at session start so the toolbar can show where the
    /// note lands even after the pending target is cleared. Nil = un-foldered.
    @State private var recordingFolder: String?

    var body: some View {
        composerWiring(ZStack {
            // The live feed UI. Disabled behind the finishing overlay while a
            // "Wait"-to-close drains the session's in-flight agents (issue #7).
            content
                .disabled(finishing || services.isClosingRecording)
            if finishing { finishingOverlay }
        })
        .background(Theme.surfaceWindow)
        // Guard the window's close: if agent tasks are still running, prompt to
        // wait for them or stop them before closing (issue #7).
        .background(
            WindowCloseGuard(
                agentsInFlight: { store.cards.contains { $0.isResearching } },
                isFinishing: { finishing },
                terminate: terminateAgents,
                waitForIdle: waitForAgentsThenClose
            )
        )
        .task {
            await services.recordingCloseTask?.value
            guard !Task.isCancelled else { return }
            setup()
        }
        .background(HostWindow.Reader(host: hostWindow))
        .onAppear(perform: installSpaceMonitor)
        .onDisappear {
            if let spaceMonitor { NSEvent.removeMonitor(spaceMonitor) }
            spaceMonitor = nil
            // A single-instance `Window` keeps its @State across close/reopen, so
            // clear the finishing overlay here or a "Wait"-close would leave a
            // stale veil on the next session.
            finishing = false
            // Closing the recording window cleanly ends an in-progress session
            // (stops audio, flushes the note, signals the sidecar) but leaves the
            // shared sidecar running so the Sessions browser keeps working. A
            // stopped-but-resumable session is still in progress (sessionStart set
            // though not listening), so end on the session, not the audio state.
            if sessionStart != nil {
                endSession()
            } else {
                cancelRecorderStart()
                recorder?.stop()
            }
            // Drafts belong to this session; the next one starts blank.
            queryText = ""
            noteDraft = NoteDraft()
            showAsk = false
            showNote = false
            // Drop any folder target so reopening the window with the global record
            // button (or ⌘N) starts un-foldered (issue #35).
            winCtx.pendingFolder = nil
            recordingFolder = nil
            services.releaseRecording()
        }
        .onChange(of: selectedDevice) { _, d in if let d { micDeviceName = d.name } }
        .onChange(of: recordingDraft.context) { _, new in
            // Push live edits to the running agents; pre-session text rides along
            // on session_start instead. Also keep the note's title in sync. Fires
            // for the whole session (including while stopped), not just recording.
            if sessionStart != nil {
                let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
                services.sidecar.sendSessionContext(trimmed)
                services.writer.updateContext(trimmed)
                services.writer.noteChanged()
            }
        }
        .onChange(of: sessionName) { _, new in
            // The name is a local label, not research context — only the note's
            // title tracks it (no sidecar push). Persisted on the next write.
            if sessionStart != nil {
                services.writer.updateName(new.trimmingCharacters(in: .whitespacesAndNewlines))
                services.writer.noteChanged()
            }
        }
        .onChange(of: recordingDraft.tags) { _, new in
            // Tags ride along on session_start before a session; once started,
            // they go straight through the writer (which flushes), so the change
            // lands in the note even when a late card rewrite would otherwise win.
            if sessionStart != nil { services.writer.setOwnedNoteTags(new) }
        }
        // A folder's record button retargets an already-open recording window; pick
        // up that folder's context and tags for the next session (issues #36/#76).
        // nil (the global record button / window close) leaves staged values untouched.
        .onChange(of: winCtx.pendingFolder) { _, _ in seedDefaultsFromPendingFolder() }
        .onChange(of: autoCards) { _, on in services.sidecar.sendAuto(on) }
        // Float the recording window, not the key window (issue #123).
        .onChange(of: pinned) { _, on in hostWindow.float(on) }
        .onReceive(NotificationCenter.default.publisher(for: .advisorConfigChanged)) { _ in
            // Preference toggles for triggers must reflect in the right-click
            // action menu immediately, not only after a relaunch; likewise the
            // saved-context library edited in Preferences.
            let cfg = AdvisorConfig.load()
            triggers = cfg.triggers
            savedContexts = cfg.contexts
            tagLibrary = cfg.tags
            recorder?.logTranscriptText = cfg.logTranscriptText // live, mid-recording too
            services.sidecar.sendLogTranscriptText(cfg.logTranscriptText)
            if sessionStart == nil {
                recordingDraft.retainKnownTags(in: cfg.tags)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .advisorTagRenamed)) { note in
            // A tag renamed in Preferences: remap it on the live note's staged
            // tags. The on-disk rename skipped this note, so the recording draft
            // onChange below (re)writes it through the writer with the new name.
            guard let from = note.userInfo?["from"] as? String,
                let to = note.userInfo?["to"] as? String
            else { return }
            let remapped = recordingDraft.tags.map {
                $0.caseInsensitiveCompare(from) == .orderedSame ? to : $0
            }
            if remapped != recordingDraft.tags { recordingDraft.tags = remapped }
        }
        .onReceive(NotificationCenter.default.publisher(for: .advisorLiveTagsChanged)) { note in
            // The Sessions browser tagged the live note; adopt its tags so a later
            // toolbar edit builds on them rather than clobbering them.
            guard let tags = note.userInfo?["tags"] as? [String] else { return }
            if tags != recordingDraft.tags { recordingDraft.tags = tags }
        }
        .onChange(of: store.utterances) { _, _ in services.writer.noteChanged() }
        // An added or deleted editorial note changes the persisted note (issue #34).
        .onChange(of: store.notes) { _, _ in services.writer.noteChanged() }
        // Only re-write the session note when output-bearing fields change — not
        // on pure UI toggles like expand/collapse (which also mutate store.cards).
        .onChange(of: cardsWriterKey) { _, _ in services.writer.noteChanged() }
        .onChange(of: agentLanes) { _, n in services.sidecar.sendLanes(n) }
        // Release the summarise guard once the card reaches a terminal state, so
        // the button re-enables for a re-summarise.
        .onChange(of: summaryResearching) { _, researching in
            if !researching { summarisingLive = false }
        }
    }

    /// ⌘K / ⇧⌘N open this window's popovers while it's in front (issue #104),
    /// and one popover shows at a time: ⌘K, ⇧⌘N and "Add note here…" open theirs
    /// whichever is showing.
    private func composerWiring(_ view: some View) -> some View {
        view
            .focusedSceneValue(
                \.composer,
                finishing || services.isClosingRecording
                    ? ComposerCommands()
                    : ComposerCommands(ask: { showAsk = true }, note: { showNote = true }))
            .onChange(of: showAsk) { _, open in if open { showNote = false } }
            .onChange(of: showNote) { _, open in if open { showAsk = false } }
    }

    /// The folder this recording is (or will be) filed into (issue #35): the
    /// pending target before Listen, the captured folder once recording. Nil =
    /// un-foldered. Shown read-only in the toolbar — the folder is fixed at start
    /// (the writer owns the live note's path), filed later via Move to Folder.
    private var targetFolder: String? {
        sessionStart != nil ? recordingFolder : winCtx.pendingFolder
    }

    /// The live feed UI — toolbar, status line, transcript.
    private var content: some View {
        VStack(spacing: 0) {
            ListeningToolbar(
                store: store,
                recordingState: recordingControl.state,
                sessionStart: sessionStart,
                stoppedAt: stoppedAt,
                targetFolder: targetFolder,
                selectedDevice: $selectedDevice,
                devices: devices,
                captureSystem: captureSystem,
                sessionName: $sessionName,
                sessionContext: $recordingDraft.context,
                sessionTags: $recordingDraft.tags,
                savedContexts: savedContexts,
                tagLibrary: tagLibrary,
                onSaveContext: saveContext(named:),
                autoCards: $autoCards,
                hideTranscript: $hideTranscript,
                pinned: $pinned,
                onStart: { startSession() },
                onResume: { resumeRecording() },
                onMuteToggle: { recorder?.setMicMuted(!store.micMuted) },
                onStop: { stopRecording() },
                canExport: services.writer.hasExportContent,
                onExport: exportSession,
                canSummarise: !store.utterances.isEmpty && !summarisingLive && !summaryResearching,
                onSummarise: submitSummarise,
                askText: $queryText,
                showAsk: $showAsk,
                onAsk: submitQuery,
                noteDraft: $noteDraft,
                showNote: $showNote,
                onNote: submitNote
            )
            statusLine
            transcriptArea
        }
    }

    /// Modal cover shown while a "Wait"-to-close finishes the in-flight agents:
    /// blocks interaction (the window is about to close) and offers an immediate
    /// stop. Dismissed when the window closes.
    private var finishingOverlay: some View {
        ZStack {
            Theme.surfaceWindow.opacity(0.9)
            VStack(spacing: 14) {
                ProgressView()
                Text("Finishing agent tasks…")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Button("Stop now", action: terminateAgents)
                    .buttonStyle(.bordered)
            }
        }
        .ignoresSafeArea()
    }

    /// Crash/error feedback, shown as a slim line under the toolbar only when
    /// there's something worth surfacing — normal idle/ready chatter is hidden.
    @ViewBuilder private var statusLine: some View {
        let text = fatalError ?? store.status
        if shouldShowStatus(text) {
            HStack(spacing: 6) {
                Circle()
                    .fill(store.listening ? Theme.recordRed
                        : (stoppedAt != nil ? Color.orange : Theme.textMuted))
                    .frame(width: 7, height: 7)
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(fatalError == nil ? Theme.textSecondary : Theme.factRed)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, Theme.Metric.contentSidePad)
            .padding(.vertical, 5)
            .background(Theme.surfaceTitlebar)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
        }
    }

    private func shouldShowStatus(_ s: String) -> Bool {
        if fatalError != nil { return true }
        let l = s.lowercased()
        return ["fail", "crash", "error", "denied", "permission", "stopped", "exhausted", "restart", "expired"]
            .contains { l.contains($0) }
    }

    private enum ScrollTarget: Hashable {
        case bottom
    }

    /// The live session as the shared feed shows it: paragraphs grouped into
    /// transcript runs between cards and notes; with the transcript hidden, only
    /// cards and notes.
    private var feedItems: [FeedItem] {
        Feed.grouped(
            Feed.live(utterances: store.utterances, cards: store.cards, notes: store.notes),
            hideTranscript: hideTranscript)
    }

    /// The live feed's actions: research and notes go to the sidecar, everything
    /// else edits the store (the session writer persists it).
    private var feedActions: FeedActions {
        FeedActions(
            transcriptActions: transcriptActions,
            onAction: { kind, selection, paragraph in
                // Anchor the card under the paragraph's last line.
                guard let anchor = paragraph.lines.last?.id else { return }
                services.sidecar.sendAction(kind, text: selection, triggerId: anchor)
            },
            onAddNote: { offset, paragraph in
                noteDraft.placement = NotePlacement(offset: offset, paragraph: paragraph)
                showNote = true
            },
            onCorrect: { request, paragraph in
                switch request.scope {
                case .thisOccurrence:
                    store.correctOccurrence(
                        request.occurrenceInParagraph, of: request.original,
                        with: request.replacement, inParagraph: Self.utteranceIds(paragraph))
                case .allInSession:
                    store.correctAll(of: request.original, with: request.replacement)
                }
            },
            onToggleCard: { store.toggleCard($0.id) },
            onDeleteCard: { card in
                // Cancel the underlying research so a deleted in-flight card
                // doesn't keep a lane busy.
                if card.isResearching { services.sidecar.sendCancel(card.id) }
                store.dismissCard(card.id)
            },
            onCancelCard: { services.sidecar.sendCancel($0.id) },
            onReply: { submitReply($0, $1) },
            onDeleteNote: { id in
                if let uuid = UUID(uuidString: id) { store.dismissNote(uuid) }
            })
    }

    /// The utterances composing a live paragraph, so a note or correction maps
    /// back to them (issue #32).
    private static func utteranceIds(_ paragraph: FeedParagraph) -> [UUID] {
        paragraph.lines.compactMap { UUID(uuidString: $0.id) }
    }

    /// The trigger to follow the tail: new lines, notes and cards, and a card
    /// that streams in place (issue #109).
    private var feedContent: TranscriptAutoScroll.Content {
        TranscriptAutoScroll.Content(utterances: store.utterances, notes: store.notes, cards: store.cards)
    }

    /// True when an editable text field has the keyboard focus in this window
    /// or in its Ask or Note popover, but not in another Advisor window, such
    /// as Preferences (issue #123). `RecordingSpaceKey` makes the same test,
    /// but in the window of the key event.
    private var isEditingTextField: Bool {
        hostWindow.isEditingText(keyWindow: NSApp.keyWindow)
    }

    /// Centred reading column: day divider, the shared feed (transcript runs,
    /// cards, notes), then the live interim line.
    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            // Built once per redraw: it re-sorts the whole session.
            let items = feedItems
            ScrollView {
                LazyVStack(alignment: .leading, spacing: FeedView.spacing) {
                    dayDivider
                    if items.isEmpty && (hideTranscript || interimText.isEmpty) {
                        Text(hideTranscript
                            ? "Cards only — answer cards appear here as they arrive."
                            : "Press Listen — the conversation and answer cards appear here.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    FeedView(items: items, actions: feedActions)
                    if !hideTranscript { interimLine }
                }
                // The same reading column as the Sessions detail; its margin holds
                // the paragraph times.
                .frame(maxWidth: Theme.Metric.readingWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Metric.contentTopPad)
                .padding(.horizontal, Theme.Metric.readingMargin)
                .padding(.bottom, Theme.Metric.contentBottomPad)
                // Target the padded feed, not its last item: aligning the last
                // item leaves the bottom padding below the visible viewport.
                .id(ScrollTarget.bottom)
            }
            .onScrollGeometryChange(for: TranscriptViewport.self) { geometry in
                TranscriptViewport(
                    visibleBottom: geometry.visibleRect.maxY,
                    contentHeight: geometry.contentSize.height,
                    containerHeight: geometry.containerSize.height)
            } action: { previous, current in
                transcriptAutoScroll.viewportChanged(from: previous, to: current)
            }
            .onChange(of: feedContent) { _, _ in
                // Don't auto-scroll while the user is typing in an editable text
                // field (the Ask or Note popover, a card reply). Scrolling the
                // transcript yanks focus away mid-keystroke, and a stray space then
                // toggles recording (issue #37). The non-editable selectable
                // transcript NSTextView is fine to scroll past.
                guard transcriptAutoScroll.scrollsOnContentChange(editingText: isEditingTextField) else { return }
                // No animation: two animated scrolls that overlap moved the
                // visible bottom back up, which read as a user scroll (#109).
                proxy.scrollTo(ScrollTarget.bottom, anchor: .bottom)
            }
        }
    }

    @ViewBuilder private var dayDivider: some View {
        if !store.utterances.isEmpty || !store.cards.isEmpty || !store.notes.isEmpty || store.listening {
            let when = store.utterances.first?.time ?? Date()
            Text(
                "Today · \(when.formatted(date: .omitted, time: .shortened)) · on-device transcription"
            )
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// What the session note holds of the cards (`Card.writerKey`).
    private var cardsWriterKey: [String] { Card.writerKey(store.cards) }

    /// The in-progress (not-yet-finalised) speech across sources.
    private var interimText: String {
        store.volatile.values.filter { !$0.isEmpty }.joined(separator: " ")
    }

    @ViewBuilder private var interimLine: some View {
        let text = interimText
        if !text.isEmpty {
            HStack(alignment: .bottom, spacing: 2) {
                Text(text)
                    .font(.system(size: Theme.Metric.transcriptSize))
                    .foregroundStyle(Theme.textTertiary)
                BlinkingCaret()
            }
            .id("interim")
        }
    }

    /// Send a follow-up about `card`. Optimistically appends the question to the
    /// body so it shows immediately; the sidecar reproduces this exact prefix and
    /// streams the answer underneath via card_update.
    private func submitReply(_ card: Card, _ reply: String) {
        guard let idx = store.cards.firstIndex(where: { $0.id == card.id }) else { return }
        let base = store.cards[idx].body
        // Send first: if the sidecar is down the message is dropped, so skip the
        // optimistic edit — otherwise the card would spin forever with no answer
        // coming and no cancel button (hidden while replying).
        let sent = services.sidecar.sendCardReply(
            cardId: card.id, kind: card.kind, title: card.title,
            base: base, replyText: reply, transcript: recentTranscript())
        guard sent else { return }
        store.cards[idx].body = SessionMarkdown.replyBody(base: base, question: reply, answer: "…")
        store.cards[idx].replying = true
        store.cards[idx].state = "streaming"
    }

    /// The tail of the live transcript, for resolving referents ("she", "that")
    /// in a follow-up. Bounded so a long session doesn't bloat the message.
    private func recentTranscript(_ limit: Int = 15) -> String {
        store.utterances.suffix(limit)
            .map { "\($0.source.rawValue): \($0.text)" }
            .joined(separator: "\n")
    }

    /// Right-click AI actions offered on selected transcript text.
    private var transcriptActions: [TranscriptAction] {
        TranscriptAction.research(for: triggers)
    }

    private func setup() {
        let cfg = AdvisorConfig.load()
        triggers = cfg.triggers
        savedContexts = cfg.contexts
        tagLibrary = cfg.tags
        devices = AudioDevices.inputs()
        // Sticky mic: restore the previously chosen device by name.
        selectedDevice =
            devices.first { $0.name == micDeviceName } ?? AudioDevices.preferred(devices)
        // The sidecar/writer are owned by AppServices (started at launch); this
        // window only builds the audio recorder.
        rebuildRecorder()
        // A window opened via a folder's record button inherits that folder's
        // defaults (issues #35/#36/#76); the pending target is already set before
        // the window appears, so seed here. An open window reseeds on change.
        seedDefaultsFromPendingFolder()
    }

    private func rebuildRecorder() {
        let manager = services.sidecar
        do {
            let config = AdvisorConfig.load()
            let built = try Recorder(store: store, locale: config.sttLocale)
            built.logTranscriptText = config.logTranscriptText
            built.onUtterance = { manager.sendUtterance($0) }
            recorder = built
            // Hand the recorder to AppServices so termination cleanup can stop
            // the audio engine before `_exit`.
            services.recorder = built
            store.status = "ready — Apple speech"
            fatalError = nil
        } catch {
            fatalError = "\(error)"
        }
    }

    /// Space toggles start/stop/resume in the recording window, except while
    /// editing a text field (where space must type a space). SwiftUI's
    /// `.keyboardShortcut` can't express that exception, so use a local key
    /// monitor instead. It gets the key events of every Advisor window, so
    /// `RecordingSpaceKey` lets through Space in any other window (issue #111),
    /// and stops the key repeats of a held Space (issue #122).
    private func installSpaceMonitor() {
        guard spaceMonitor == nil else { return }
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !services.isClosingRecording else { return event }
            switch RecordingSpaceKey.effect(of: event, recordingWindow: hostWindow.window) {
            case .pass: return event
            case .ignore: return nil
            case .toggle: break
            }
            switch recordingControl.state {
            case .recording: stopRecording()
            case .stopped: resumeRecording()
            case .idle: startSession()
            }
            return nil
        }
    }

    /// Stop audio capture but keep the session resumable: the note and the
    /// sidecar's classifier session stay live (no `session_end`), so resuming
    /// continues the same session with full context. Freezes the timer at this
    /// moment. The session is finalised only when the window closes (issue #6).
    private func stopRecording() {
        guard let recorder else { return }
        recordingControl.stop(recorder: recorder)
    }

    /// Resume a stopped session: shift `sessionStart` forward by the stopped span
    /// so the timer continues from where it froze, then restart audio into the
    /// same session (no generation bump, so existing utterances are kept; no new
    /// `session_start`/note). The frozen-timer state holds until audio is live.
    private func resumeRecording() {
        guard let recorder, !services.isClosingRecording else { return }
        recordingControl.resume(recorder: recorder,
            device: selectedDevice, captureSystem: captureSystem)
    }

    private func cancelRecorderStart() {
        recordingControl.cancelStart()
    }

    /// Share the current session note to a chosen location via a save panel.
    /// The saved note is already in the window's inline-card format, so this
    /// just copies the file.
    private func exportSession() {
        let writer = services.writer
        guard writer.hasExportContent else { return }
        guard let url = exportDestination(suggestedName: writer.suggestedFilename()) else { return }
        do {
            try writer.export(to: url)
        } catch {
            store.status = "export failed: \(error.localizedDescription)"
        }
    }

    /// Save the current Context popover text under `name` as a reusable context
    /// (issue #10), persisting to config.json and posting the config-changed
    /// notification so Preferences (if open) and this view reflect it.
    private func saveContext(named name: String) {
        savedContexts = ContextLibrary.saving(
            savedContexts, name: name, text: recordingDraft.context)
        AdvisorConfig.persistContexts(savedContexts)
        NotificationCenter.default.post(name: .advisorConfigChanged, object: nil)
    }

    private func submitQuery() {
        let text = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !services.isClosingRecording else { return }
        services.sidecar.sendQuery(text)
        queryText = ""
        showAsk = false
    }

    /// Add the Note popover's draft (issue #104): under the line "Add note here…"
    /// was chosen on, or — opened from the toolbar or ⇧⌘N — at this point in the
    /// conversation, after every line heard so far.
    /// Refused while the last window's close is still finishing: it clears the
    /// store's notes when it does. A placement whose lines have all gone (echo
    /// cleanup) is dropped instead, so the popover shows the note going here.
    private func submitNote() {
        guard !services.isClosingRecording else { return }
        if let placement = noteDraft.placement, store.lines(Self.utteranceIds(placement.paragraph)).isEmpty {
            noteDraft.placement = nil
            return
        }
        let added = noteDraft.submit { text, placement in
            if let placement {
                addNote(text, atOffset: placement.offset, in: Self.utteranceIds(placement.paragraph))
            } else {
                addNote(text, at: Date())
            }
            return true
        }
        if added { showNote = false }
    }

    /// Inject an editorial note at a line of the transcript (issue #34). `offset`
    /// is the selection end / click point within the clicked paragraph, mapped
    /// back to the line it falls in so the note anchors at the selected text —
    /// above any card or transcript below it.
    private func addNote(_ text: String, atOffset offset: Int, in utteranceIds: [UUID]) {
        addNote(text, at: NoteAnchor.time(forOffset: offset, in: store.lines(utteranceIds)) ?? Date())
    }

    /// Inject an editorial note at `time`, sent to the sidecar as transcript
    /// context the agents read. In a session it triggers a rewrite so it
    /// persists. Before Listen (issue #104) a question asked then reads it too,
    /// and Listen sends it again, after `session_start` clears the transcript.
    private func addNote(_ text: String, at time: Date) {
        guard let note = store.addNote(text, at: time) else { return }
        services.sidecar.sendNote(note)
        if sessionStart != nil { services.writer.noteChanged() }
    }

    /// Summarise the whole live session into its single Summary card (issue #30).
    /// Re-running passes the existing summary card's id so the sidecar updates it
    /// in place rather than adding a second summary.
    private func submitSummarise() {
        guard !store.utterances.isEmpty, !summarisingLive, !summaryResearching else { return }
        let transcript = store.utterances
            .map { "\($0.source.rawValue): \($0.text)" }
            .joined(separator: "\n")
        let existing = store.cards.first { $0.kind == "summary" }?.id
        summarisingLive = true
        // If the sidecar is down nothing comes back, so release the guard now.
        if !services.sidecar.sendSummariseLive(cardId: existing, transcript: transcript) {
            summarisingLive = false
        }
    }

    /// Whether the session's summary card is currently being produced.
    private var summaryResearching: Bool {
        store.cards.contains { $0.kind == "summary" && $0.isResearching }
    }

    /// Finalise the current session: stop audio, signal the sidecar, flush the
    /// note, and clear the session state. Leaves the shared sidecar running.
    /// Called when the window closes (or its "Wait"-to-close path) — Stop alone no
    /// longer ends a session, since it's now resumable (issue #6). Safe whether
    /// the session was recording or already stopped.
    @discardableResult
    private func endSession() -> Task<Void, Never> {
        cancelRecorderStart()
        let end = services.endRecording()
        // Clear `sessionStart` first: the field clears below fire onChange, and
        // the tags handler persists through the (ungated) writer — with the
        // session already ended, that would flush empty tags over the saved note.
        recordingControl.end()
        recordingDraft.context = "" // blank slate for the next session
        sessionName = ""
        recordingDraft.tags = []
        recordingFolder = nil
        return end
    }

    /// Cancel every in-flight agent for this session and mark each cancelled so
    /// the final note write reflects it. The shared sidecar keeps running for the
    /// Sessions browser — only this session's tasks stop. ("Stop and Close".)
    private func terminateAgents() {
        for idx in store.cards.indices where store.cards[idx].isResearching {
            services.sidecar.sendCancel(store.cards[idx].id)
            store.cards[idx].cancel()
        }
    }

    /// Stop recording (so no new agents spawn), cover the window, and close it
    /// once the in-flight agents reach a terminal state — flushing the note
    /// first. Polls the card states, which update on the main actor as
    /// `card_update` frames arrive. Closes via SwiftUI's `dismissWindow` so the
    /// window's `onDisappear` cleanup actually runs. ("Wait".)
    private func waitForAgentsThenClose() {
        let end = endSession()
        // Cover the window and drop the Space monitor: recording has stopped, so
        // a stray Space would otherwise start a fresh session mid-close.
        if let spaceMonitor { NSEvent.removeMonitor(spaceMonitor) }
        spaceMonitor = nil
        withAnimation { finishing = true }
        // Backstop: a card wedged in "researching" (e.g. a sidecar crash before
        // issue #49's fix runs, or any other stall) would otherwise make poll()
        // recurse forever and the window never close. Bound it at ~200s — just
        // beyond the sidecar's 180s per-task timeout, so a legitimately-completing
        // card is never truncated. 200s / 0.3s ≈ 667 polls.
        let maxPolls = 667
        var polls = 0
        func closeNow() {
            services.writer.flush()
            // Drop the overlay before dismissing so the close guard (which
            // ignores closes while finishing) lets this one through, and no
            // stale veil survives on the single-instance window's reuse.
            finishing = false
            dismissWindow(id: "recording")
        }
        func poll() {
            if !store.cards.contains(where: { $0.isResearching }) {
                closeNow()
                return
            }
            polls += 1
            if polls >= maxPolls {
                appLog.write("waitForAgentsThenClose: forcing close with cards still in-flight after ~200s")
                closeNow()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: poll)
        }
        Task { @MainActor in
            await end.value
            poll()
        }
    }

    /// Seed the session context and tags from folder defaults (issues #36/#76)
    /// when opened via a folder's record button. Both remain editable per session.
    /// Skipped once live — the running session owns its values.
    private func seedDefaultsFromPendingFolder() {
        recordingDraft.seedFromFolder(
            pendingFolder: winCtx.pendingFolder,
            sessionActive: sessionStart != nil,
            library: tagLibrary)
    }

    /// Start a fresh session from idle: a new STT generation, a new note and a new
    /// sidecar session. Stop no longer ends a session (it's resumable), so this
    /// only runs from the idle Listen control — a new session means closing the
    /// window and opening a new one from the Sessions browser.
    private func startSession() {
        guard let recorder, sessionStart == nil, !services.isClosingRecording else { return }
        // Open a new STT session generation before clearing/starting, on the
        // main actor with no `await` in between, so a previous session's
        // in-flight finals are already stale by the time they try to write.
        // Notes typed before Listen are kept, and sent after `session_start`,
        // which clears the sidecar's transcript (issue #104).
        let pendingNotes = store.beginSession()
        let ctx = recordingDraft.context.trimmingCharacters(in: .whitespacesAndNewlines)
        let nm = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Consume the pending folder target: this session files into it, and it's
        // cleared so it can't leak to a later un-foldered recording (issue #35).
        let folder = winCtx.pendingFolder
        recordingFolder = folder
        winCtx.pendingFolder = nil
        services.sidecar.sendSessionStart(UUID().uuidString, context: ctx, notes: pendingNotes)
        services.writer.start(
            context: ctx, name: nm, tags: recordingDraft.tags, folder: folder)
        // A transcript window opened on this note must disable asking until
        // the live writer is done with it.
        TranscriptWindowContext.shared.liveFileURL = services.writer.currentFileURL
        recordingControl.start(recorder: recorder,
            device: selectedDevice, captureSystem: captureSystem)
    }
}

/// A thin caret that blinks at the end of the live interim transcript line.
struct BlinkingCaret: View {
    @State private var on = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Theme.accent)
            .frame(width: 2.5, height: 17)
            .opacity(on ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    on = false
                }
            }
    }
}
