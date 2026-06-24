import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Repo root, derived from this source file's compile-time location so the
// checkout can move without editing paths. Sources/Advisor/AdvisorApp.swift
// is four levels below the repo root (…/App/Sources/Advisor/AdvisorApp.swift).
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Advisor/
    .deletingLastPathComponent()   // Sources/
    .deletingLastPathComponent()   // App/
    .deletingLastPathComponent()   // repo root

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    /// Orderly teardown registered by the view (stop sidecar child + audio,
    /// flush the session). Re-registered whenever the recorder is rebuilt.
    var onTerminate: (() -> Void)?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        applyAppearance(AdvisorConfig.load().appearance)
        // Reapply when the appearance preference changes, without a relaunch.
        NotificationCenter.default.addObserver(
            forName: .advisorConfigChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyAppearance(AdvisorConfig.load().appearance)
        }
    }

    /// Force the app's appearance from the saved preference. "system" clears the
    /// override so the app follows macOS; the Theme's dynamic colours resolve
    /// against `NSApp.effectiveAppearance`, so this drives the whole UI.
    private func applyAppearance(_ value: String) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    /// On Cmd-Q, AppKit calls `exit()`, which runs C++ static destructors.
    /// ggml-metal registers a global Metal-device vector whose destructor
    /// hits `ggml_abort` at process-exit (the same teardown hazard the smoke
    /// test sidesteps with deinit-before-exit ordering). Do our own orderly
    /// cleanup, then `_exit` to bypass those finalisers entirely.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        onTerminate?()
        _exit(0)
    }
}

@main
struct AdvisorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var services = AppServices()
    @AppStorage("agentLanes") private var agentLanes = 3

    var body: some Scene {
        // The Sessions browser is the main window: it opens at launch and is a
        // single shared master/detail window. Starting `services` here (not in
        // the recording window) keeps the sidecar alive so saved transcripts can
        // be queried with no recording window open.
        Window("Sessions", id: "sessions") {
            SessionsView()
                .task { services.start(lanes: agentLanes) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.presented)
        // The recording window — single-instance by virtue of being a `Window`
        // (not a `WindowGroup`): the Sessions "New" button opens it, and
        // re-opening just brings the existing one forward. Never auto-opens.
        Window("Recording", id: "recording") {
            TranscriptView(services: services)
                .frame(minWidth: 420, minHeight: 480)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        // Cmd-N opens the single recording window (or brings it forward),
        // replacing the menu bar's default "New" — there's no document to create.
        .commands { RecordingCommands() }
        Settings {
            PreferencesView()
        }
    }
}

/// Menu-bar commands: Cmd-N starts a recording. Lives as a `Commands` type so it
/// can read `openWindow` from the environment (the App struct can't directly).
struct RecordingCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Recording") { openWindow(id: "recording") }
                .keyboardShortcut("n", modifiers: .command)
        }
    }
}

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
    @State private var queryText = ""
    /// True from the instant Summarise is tapped until the summary card reaches a
    /// terminal state. Guards the gap before the card returns, so a fast
    /// double-click can't spawn a second summary card (issue #30).
    @State private var summarisingLive = false

    init(services: AppServices) {
        self.services = services
        _store = ObservedObject(wrappedValue: services.store)
    }
    /// The session prompt: optional free-text context. Filled before Listen
    /// (sent on session_start) or edited live during the session (pushed via
    /// onChange). Cleared when the session stops.
    @State private var sessionContext = ""
    /// The optional session name: a short label, distinct from the research
    /// context. Filled before Listen (seeded into the writer at start) or edited
    /// live; titles the session in the browser. Cleared when the session stops.
    @State private var sessionName = ""
    /// The session's tags (issue #15). Staged before Listen (seeded into the
    /// writer at start) or edited live via the toolbar's Tags chip; rendered as
    /// coloured pills in the browser. Cleared when the session stops.
    @State private var sessionTags: [String] = []
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
    @State private var pinned = false
    /// When the current session started — drives the toolbar timer. Non-nil for
    /// the whole session (Listen until the window closes), even while stopped.
    /// Shifted forward by each stop's duration so the timer excludes stops.
    @State private var sessionStart: Date?
    /// When stopped, the moment of stopping — freezes the timer and marks the
    /// session resumable. Nil while recording or idle.
    @State private var stoppedAt: Date?
    @State private var spaceMonitor: Any?
    /// True while a "Wait"-to-close is draining the session's in-flight agents.
    /// Covers the window with a blocking overlay so the about-to-close UI can't
    /// be driven (e.g. Space starting a fresh session). Cleared by the close.
    @State private var finishing = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("agentLanes") private var agentLanes = 3
    @AppStorage("micDeviceName") private var micDeviceName = ""

    var body: some View {
        ZStack {
            // The live feed UI. Disabled behind the finishing overlay while a
            // "Wait"-to-close drains the session's in-flight agents (issue #7).
            content
                .disabled(finishing)
            if finishing { finishingOverlay }
        }
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
        .task { setup() }
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
            if sessionStart != nil { endSession() }
            services.recorder = nil
            // Detach the writer from the just-saved note and drop the live lock
            // BEFORE clearing the shared store, so neither the store-clear's change
            // notification nor the app-terminate flush can rewrite the note from an
            // emptied store. The note is already on disk; the Sessions browser now
            // treats it as a normal saved note (renamed/queried via disk).
            services.writer.releaseNote()
            TranscriptWindowContext.shared.liveFileURL = nil
            // The store is app-lifetime (owned by AppServices); clear the rendered
            // session so reopening the recording window starts blank. Bump the STT
            // generation as part of the reset (onDisappear runs atomically on the
            // main actor) so this just-closed session's still-processing finals are
            // dropped instead of appended to the blank store the next window shows.
            store.sessionGeneration += 1
            store.utterances = []
            store.cards = []
            store.notes = []
            store.volatile = [:]
        }
        .onChange(of: selectedDevice) { _, d in if let d { micDeviceName = d.name } }
        .onChange(of: sessionContext) { _, new in
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
        .onChange(of: sessionTags) { _, new in
            // Tags ride along on session_start before a session; once started,
            // they go straight through the writer (which flushes), so the change
            // lands in the note even when a late card rewrite would otherwise win.
            if sessionStart != nil { services.writer.setOwnedNoteTags(new) }
        }
        .onChange(of: autoCards) { _, on in services.sidecar.sendAuto(on) }
        .onChange(of: pinned) { _, on in
            // Prefer the key window (the recording window, since its toolbar holds
            // the pin toggle) now that the Sessions window is also on screen.
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible)
            else { return }
            window.level = on ? .floating : .normal
            window.collectionBehavior = on ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
        }
        .onReceive(NotificationCenter.default.publisher(for: .advisorConfigChanged)) { _ in
            // Preference toggles for triggers must reflect in the right-click
            // action menu immediately, not only after a relaunch; likewise the
            // saved-context library edited in Preferences.
            let cfg = AdvisorConfig.load()
            triggers = cfg.triggers
            savedContexts = cfg.contexts
            tagLibrary = cfg.tags
        }
        .onReceive(NotificationCenter.default.publisher(for: .advisorTagRenamed)) { note in
            // A tag renamed in Preferences: remap it on the live note's staged
            // tags. The on-disk rename skipped this note, so the sessionTags
            // onChange below (re)writes it through the writer with the new name.
            guard let from = note.userInfo?["from"] as? String,
                let to = note.userInfo?["to"] as? String
            else { return }
            let remapped = sessionTags.map {
                $0.caseInsensitiveCompare(from) == .orderedSame ? to : $0
            }
            if remapped != sessionTags { sessionTags = remapped }
        }
        .onReceive(NotificationCenter.default.publisher(for: .advisorLiveTagsChanged)) { note in
            // The Sessions browser tagged the live note; adopt its tags so a later
            // toolbar edit builds on them rather than clobbering them.
            guard let tags = note.userInfo?["tags"] as? [String] else { return }
            if tags != sessionTags { sessionTags = tags }
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

    /// The live feed UI — toolbar, status line, transcript, ask bar.
    private var content: some View {
        VStack(spacing: 0) {
            ListeningToolbar(
                store: store,
                sessionStart: sessionStart,
                stoppedAt: stoppedAt,
                selectedDevice: $selectedDevice,
                devices: devices,
                captureSystem: captureSystem,
                sessionName: $sessionName,
                sessionContext: $sessionContext,
                sessionTags: $sessionTags,
                savedContexts: savedContexts,
                tagLibrary: tagLibrary,
                onSaveContext: saveContext(named:),
                autoCards: $autoCards,
                hideTranscript: $hideTranscript,
                pinned: $pinned,
                onStart: { Task { await startSession() } },
                onResume: { resumeRecording() },
                onMuteToggle: { recorder?.setMicMuted(!store.micMuted) },
                onStop: { stopRecording() },
                canExport: services.writer.hasExportContent,
                onExport: exportSession,
                canSummarise: !store.utterances.isEmpty && !summarisingLive && !summaryResearching,
                onSummarise: submitSummarise
            )
            statusLine
            transcriptArea
            AskBar(
                text: $queryText,
                onSubmit: submitQuery
            )
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
        return ["fail", "crash", "error", "denied", "permission", "stopped", "exhausted", "restart"]
            .contains { l.contains($0) }
    }

    private enum FeedItem: Identifiable {
        case utterance(Utterance)
        case card(Card)
        case note(EditorialNote)

        var id: String {
            switch self {
            case .utterance(let u): "u-\(u.id.uuidString)"
            case .card(let c): "c-\(c.id)"
            case .note(let n): "n-\(n.id.uuidString)"
            }
        }

        var time: Date {
            switch self {
            case .utterance(let u): u.time
            case .card(let c): c.created
            case .note(let n): n.time
            }
        }

        var isUtterance: Bool {
            if case .utterance = self { return true }
            return false
        }

        /// Tie-break rank at equal times: an utterance (0) first, then the user's
        /// own note (1) hugging its line, then any card (2) below it (issue #34).
        var rank: Int {
            switch self {
            case .utterance: 0
            case .note: 1
            case .card: 2
            }
        }
    }

    /// Transcript, cards and editorial notes merged chronologically, so answers
    /// and the user's own notes appear in context. At equal times an utterance
    /// sorts first, then a note anchored to that line, then a card — so the note
    /// hugs its text and the card sits below.
    private var feed: [FeedItem] {
        (store.utterances.map(FeedItem.utterance)
            + store.cards.map(FeedItem.card)
            + store.notes.map(FeedItem.note))
            .sorted { a, b in
                a.time != b.time ? a.time < b.time : a.rank < b.rank
            }
    }

    /// A run of consecutive utterances rendered as one flowing paragraph.
    private struct Paragraph: Identifiable {
        let id: String
        let text: String
        let toolTip: String
        /// Last utterance in the run — manual right-click cards anchor here.
        let anchorId: String
        /// Every utterance in the run, in order — a correction maps a paragraph
        /// selection back to the utterance(s) that compose it (issue #32).
        let utteranceIds: [UUID]
    }

    private enum RenderItem: Identifiable {
        case paragraph(Paragraph)
        case card(Card)
        case note(EditorialNote)

        var id: String {
            switch self {
            case .paragraph(let p): "p-\(p.id)"
            case .card(let c): "c-\(c.id)"
            case .note(let n): "n-\(n.id.uuidString)"
            }
        }
    }

    /// A feed row for display: each run of consecutive paragraphs between cards
    /// collapses into one transcript card, so transcript and answers read as
    /// distinct stacked cards.
    private enum DisplayItem: Identifiable {
        case transcript([Paragraph])
        case card(Card)
        case note(EditorialNote)

        var id: String {
            switch self {
            case .transcript(let ps): "t-\(ps.first?.id ?? "empty")"
            case .card(let c): "c-\(c.id)"
            case .note(let n): "n-\(n.id.uuidString)"
            }
        }
    }

    /// The feed collapsed for display: consecutive utterances join into a single
    /// paragraph so the transcript reads as prose. A new paragraph starts when
    /// the gap to the previous line exceeds 2s, or when a card interrupts.
    private var renderItems: [RenderItem] {
        var items: [RenderItem] = []
        var buf: [Utterance] = []
        func flush() {
            guard let first = buf.first, let last = buf.last else { return }
            items.append(
                .paragraph(
                    Paragraph(
                        id: first.id.uuidString,
                        text: buf.map(\.text).joined(separator: " "),
                        toolTip: first.time.formatted(date: .omitted, time: .standard),
                        anchorId: last.id.uuidString,
                        utteranceIds: buf.map(\.id))))
            buf.removeAll()
        }
        for item in feed {
            switch item {
            case .utterance(let u):
                if let last = buf.last, u.time.timeIntervalSince(last.time) > 2 { flush() }
                buf.append(u)
            case .card(let c):
                flush()
                items.append(.card(c))
            case .note(let n):
                flush()
                items.append(.note(n))
            }
        }
        flush()
        return items
    }

    /// `renderItems` grouped for display: each run of consecutive paragraphs
    /// between cards becomes one transcript card. With the transcript hidden
    /// (experiment) paragraphs are dropped, leaving only answer cards.
    private var displayedItems: [DisplayItem] {
        var items: [DisplayItem] = []
        var buf: [Paragraph] = []
        func flush() {
            if !buf.isEmpty { items.append(.transcript(buf)); buf.removeAll() }
        }
        for item in renderItems {
            switch item {
            case .paragraph(let p):
                if hideTranscript { continue }
                buf.append(p)
            case .card(let c):
                flush()
                items.append(.card(c))
            case .note(let n):
                // Notes are the user's own signal, not transcript chatter, so they
                // stay visible even in cards-only mode.
                flush()
                items.append(.note(n))
            }
        }
        flush()
        return items
    }

    /// Changes whenever a final line or card is added — the auto-scroll trigger
    /// (a growing paragraph keeps its id, so id-based scrolling alone misses it).
    private var scrollKey: String {
        "\(store.utterances.count)|\(store.cards.count)|\(store.notes.count)"
    }

    /// Centered transcript column (max-width 812): day divider, flowing
    /// paragraphs, inline cards, then the live interim line.
    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Metric.paragraphSpacing) {
                    dayDivider
                    if displayedItems.isEmpty && (hideTranscript || interimText.isEmpty) {
                        Text(hideTranscript
                            ? "Cards only — answer cards appear here as they arrive."
                            : "Press Listen — the conversation and answer cards appear here.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(displayedItems) { item in
                        switch item {
                        case .transcript(let paragraphs):
                            transcriptCard(paragraphs)
                                .id(item.id)
                        case .card(let card):
                            ListeningCardView(
                                card: card,
                                onToggleExpand: { store.toggleCard(card.id) },
                                onDismiss: {
                                    // Cancel the underlying research so a dismissed
                                    // in-flight card doesn't keep a lane busy.
                                    if card.isResearching { services.sidecar.sendCancel(card.id) }
                                    store.dismissCard(card.id)
                                },
                                onCancel: { services.sidecar.sendCancel(card.id) },
                                onReply: { submitReply(card, $0) }
                            )
                            .id(item.id)
                        case .note(let note):
                            EditorialNoteView(
                                note: note,
                                onDismiss: { store.dismissNote(note.id) }
                            )
                            .id(item.id)
                        }
                    }
                    if !hideTranscript { interimLine }
                }
                .frame(maxWidth: Theme.Metric.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Metric.contentTopPad)
                .padding(.horizontal, Theme.Metric.contentSidePad)
                .padding(.bottom, Theme.Metric.contentBottomPad)
            }
            .onChange(of: scrollKey) { _, _ in
                if let last = displayedItems.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    /// A run of transcript between cards, wrapped in card chrome. Each paragraph
    /// keeps its own selectable text view so right-click actions and corrections
    /// still map back to the utterance(s) that compose it.
    @ViewBuilder private func transcriptCard(_ paragraphs: [Paragraph]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metric.paragraphSpacing) {
            ForEach(paragraphs) { p in
                SelectableTranscriptText(
                    text: p.text,
                    toolTip: p.toolTip,
                    actions: transcriptActions,
                    onAction: { kind, selection in
                        services.sidecar.sendAction(
                            kind, text: selection, triggerId: p.anchorId)
                    },
                    onAddNote: { noteText, offset in
                        addNote(noteText, atOffset: offset, in: p.utteranceIds)
                    },
                    onCorrect: { request in
                        switch request.scope {
                        case .thisOccurrence:
                            store.correctOccurrence(
                                request.occurrenceInParagraph, of: request.original,
                                with: request.replacement, inParagraph: p.utteranceIds)
                        case .allInSession:
                            store.correctAll(
                                of: request.original, with: request.replacement)
                        }
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surfaceCardInset, in: RoundedRectangle(cornerRadius: Theme.Metric.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metric.cardRadius)
                .stroke(Theme.hairline, lineWidth: 0.5))
    }

    @ViewBuilder private var dayDivider: some View {
        if !feed.isEmpty || store.listening {
            let when = store.utterances.first?.time ?? Date()
            Text(
                "Today · \(when.formatted(date: .omitted, time: .shortened)) · on-device transcription"
            )
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// Signature of the card fields the session writer actually renders, so a
    /// rewrite is triggered by content/lifecycle changes but not by expand/
    /// collapse. Card add/remove changes the array length, also caught here.
    private var cardsWriterKey: [String] {
        store.cards.map {
            "\($0.id)|\($0.state)|\($0.title)|\($0.body)|\($0.verdict?.rawValue ?? "")|\($0.sources.count)"
        }
    }

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
        store.cards[idx].body = base + "\n\n---\n\n**You:** \(reply)\n\n…"
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

    /// Right-click AI actions offered on selected transcript text — the same
    /// trigger kinds the auto-classifier uses, gated by the same config toggles
    /// (so a kind disabled in Preferences never appears here either). The kind
    /// string is the card kind the sidecar emits.
    private var transcriptActions: [TranscriptAction] {
        var actions: [TranscriptAction] = []
        if triggers.question { actions.append(TranscriptAction(title: "Answer", kind: "answer")) }
        if triggers.context { actions.append(TranscriptAction(title: "Context", kind: "context")) }
        if triggers.factcheck {
            actions.append(TranscriptAction(title: "Fact check", kind: "factcheck"))
        }
        return actions
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
    }

    private func rebuildRecorder() {
        let manager = services.sidecar
        do {
            let built = try Recorder(
                store: store, locale: AdvisorConfig.load().sttLocale)
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

    /// Space toggles start/stop/resume globally, except while editing a text
    /// field (where space must type a space). SwiftUI's `.keyboardShortcut`
    /// can't express that exception, so use a local key monitor instead.
    private func installSpaceMonitor() {
        guard spaceMonitor == nil else { return }
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            else { return event }
            // Don't steal space from a focused *editable* text field (the Ask
            // box). The selectable transcript is a non-editable NSTextView and
            // must still toggle recording when it holds focus.
            if let tv = event.window?.firstResponder as? NSTextView, tv.isEditable { return event }
            switch RecordControl.state(listening: store.listening, stopped: stoppedAt != nil) {
            case .recording: stopRecording()
            case .stopped: resumeRecording()
            case .idle: Task { await startSession() }
            }
            return nil
        }
    }

    /// Stop audio capture but keep the session resumable: the note and the
    /// sidecar's classifier session stay live (no `session_end`), so resuming
    /// continues the same session with full context. Freezes the timer at this
    /// moment. The session is finalised only when the window closes (issue #6).
    private func stopRecording() {
        guard store.listening else { return }
        stoppedAt = Date()
        recorder?.stop()
    }

    /// Resume a stopped session: shift `sessionStart` forward by the stopped span
    /// so the timer continues from where it froze, then restart audio into the
    /// same session (no generation bump, so existing utterances are kept; no new
    /// `session_start`/note). The frozen-timer state holds until audio is live.
    private func resumeRecording() {
        guard let recorder, let stoppedAt else { return }
        if let start = sessionStart {
            sessionStart = RecordControl.resumedStart(start, stoppedAt: stoppedAt, now: Date())
        }
        Task {
            await recorder.start(device: selectedDevice, captureSystem: captureSystem)
            await MainActor.run { self.stoppedAt = nil }
        }
    }

    /// Share the current session note to a chosen location via a save panel.
    /// The saved note is already in the window's inline-card format, so this
    /// just copies the file.
    private func exportSession() {
        let writer = services.writer
        guard writer.hasExportContent else { return }
        let panel = NSSavePanel()
        panel.title = "Export Session"
        panel.nameFieldStringValue = writer.suggestedFilename()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
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
        savedContexts = ContextLibrary.saving(savedContexts, name: name, text: sessionContext)
        AdvisorConfig.persistContexts(savedContexts)
        NotificationCenter.default.post(name: .advisorConfigChanged, object: nil)
    }

    private func submitQuery() {
        let text = queryText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        services.sidecar.sendQuery(text)
        queryText = ""
    }

    /// Inject an editorial note the user typed via the transcript right-click menu
    /// (issue #34). `offset` is the selection end / click point within the clicked
    /// paragraph, mapped back to the line it falls in so the note anchors at the
    /// selected text — above any card or transcript below it. Forwards it to the
    /// sidecar as transcript context the agents read, and triggers a rewrite so it
    /// persists.
    private func addNote(_ text: String, atOffset offset: Int, in utteranceIds: [UUID]) {
        let lines = utteranceIds.compactMap { id in
            store.utterances.first { $0.id == id }.map { (text: $0.text, time: $0.time) }
        }
        let anchorTime = NoteAnchor.time(forOffset: offset, in: lines) ?? Date()
        guard let note = store.addNote(text, at: anchorTime) else { return }
        services.sidecar.sendNote(note)
        services.writer.noteChanged()
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
    private func endSession() {
        recorder?.stop()
        services.sidecar.sendSessionEnd()
        services.writer.end()
        // Clear `sessionStart` first: the field clears below fire onChange, and
        // the tags handler persists through the (ungated) writer — with the
        // session already ended, that would flush empty tags over the saved note.
        sessionStart = nil
        stoppedAt = nil
        sessionContext = "" // blank slate for the next session
        sessionName = ""
        sessionTags = []
    }

    /// Cancel every in-flight agent for this session and mark each cancelled so
    /// the final note write reflects it. The shared sidecar keeps running for the
    /// Sessions browser — only this session's tasks stop. ("Stop and Close".)
    private func terminateAgents() {
        for idx in store.cards.indices where store.cards[idx].isResearching {
            services.sidecar.sendCancel(store.cards[idx].id)
            store.cards[idx].state = "cancelled"
        }
    }

    /// Stop recording (so no new agents spawn), cover the window, and close it
    /// once the in-flight agents reach a terminal state — flushing the note
    /// first. Polls the card states, which update on the main actor as
    /// `card_update` frames arrive. Closes via SwiftUI's `dismissWindow` so the
    /// window's `onDisappear` cleanup actually runs. ("Wait".)
    private func waitForAgentsThenClose() {
        if sessionStart != nil { endSession() }
        // Cover the window and drop the Space monitor: recording has stopped, so
        // a stray Space would otherwise start a fresh session mid-close.
        if let spaceMonitor { NSEvent.removeMonitor(spaceMonitor) }
        spaceMonitor = nil
        withAnimation { finishing = true }
        func poll() {
            if !store.cards.contains(where: { $0.isResearching }) {
                services.writer.flush()
                // Drop the overlay before dismissing so the close guard (which
                // ignores closes while finishing) lets this one through, and no
                // stale veil survives on the single-instance window's reuse.
                finishing = false
                dismissWindow(id: "recording")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: poll)
        }
        poll()
    }

    /// Start a fresh session from idle: a new STT generation, a new note and a new
    /// sidecar session. Stop no longer ends a session (it's resumable), so this
    /// only runs from the idle Listen control — a new session means closing the
    /// window and opening a new one from the Sessions browser.
    private func startSession() async {
        guard let recorder, sessionStart == nil else { return }
        // Open a new STT session generation before clearing/starting, on the
        // main actor with no `await` in between, so a previous session's
        // in-flight finals are already stale by the time they try to write.
        store.sessionGeneration += 1
        store.utterances = []
        store.cards = []
        store.notes = []
        sessionStart = Date()
        stoppedAt = nil
        let ctx = sessionContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let nm = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        services.sidecar.sendSessionStart(UUID().uuidString, context: ctx)
        services.writer.start(context: ctx, name: nm, tags: sessionTags)
        // A transcript window opened on this note must disable asking until
        // the live writer is done with it.
        TranscriptWindowContext.shared.liveFileURL = services.writer.currentFileURL
        await recorder.start(device: selectedDevice, captureSystem: captureSystem)
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

/// One right-click AI action: a menu title and the card kind it requests.
struct TranscriptAction {
    let title: String
    let kind: String
}

/// A transcription correction chosen from the right-click menu (issue #32).
/// `occurrenceInParagraph` is the 0-based index of the highlighted span among
/// matches of `original` in the displayed paragraph — used only to pin the exact
/// instance for `.thisOccurrence`; `.allInSession` ignores it.
struct TranscriptCorrectionRequest {
    enum Scope { case thisOccurrence, allInSession }
    let original: String
    let replacement: String
    let occurrenceInParagraph: Int
    let scope: Scope
}

/// Selectable transcript line backed by an NSTextView, so the right-click menu
/// can act on the exact highlighted span (SwiftUI's `Text` selection is opaque
/// to a `.contextMenu`). Falls back to the whole line when nothing is selected.
struct SelectableTranscriptText: NSViewRepresentable {
    let text: String
    let toolTip: String
    let actions: [TranscriptAction]
    /// (card kind, selected text) — fired when an AI action is chosen.
    let onAction: (String, String) -> Void
    /// Fired with (entered text, selection-end/click offset within this
    /// paragraph) when the user adds an editorial note here (issue #34). Nil hides
    /// the "Add note" menu item — e.g. saved notes in the browser, where notes are
    /// only injected into the live feed.
    var onAddNote: ((String, Int) -> Void)? = nil
    /// Fired when a correction is confirmed (issue #32). Nil hides the correction
    /// menu items — e.g. the still-being-written live note in the browser.
    var onCorrect: ((TranscriptCorrectionRequest) -> Void)? = nil

    func makeNSView(context: Context) -> ActionTextView {
        // Convenience init builds a TextKit stack the view *owns* (storage
        // included) — a hand-built stack would leave storage/layoutManager
        // unretained and they'd deallocate. Touching `layoutManager` forces the
        // TextKit 1 fallback so it's available for height measurement (TextKit 2
        // leaves it nil).
        let tv = ActionTextView(frame: .zero)
        _ = tv.layoutManager
        // Height is reported through the view's own intrinsicContentSize (see
        // ActionTextView), recomputed for whatever width SwiftUI lays it out at.
        // The container width tracks the frame, so the measured height can never
        // diverge from the drawn wrap width — a custom sizeThatFits could commit a
        // height from a probe wider than the final draw, clipping wrapped lines on
        // session switch (issue #12).
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.lineFragmentPadding = 0
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.drawsBackground = false
        tv.backgroundColor = NSColor.clear
        tv.textContainerInset = NSSize.zero
        // Populate content here too, not only in updateNSView: when a session is
        // selected the whole detail VStack is built at once, so the first height
        // read must already see the real text.
        apply(to: tv)
        return tv
    }

    func updateNSView(_ tv: ActionTextView, context: Context) {
        apply(to: tv)
    }

    /// Push the current text + styling into the view's storage. isRichText is
    /// false, so style the storage directly — typingAttributes alone won't
    /// reflow already-set text, and height measurement reads the storage's
    /// paragraph style.
    private func apply(to tv: ActionTextView) {
        if tv.string != text { tv.string = text }
        // Transcript body type: 14.5 pt, line-height 1.2, semantic body colour.
        let font = NSFont.systemFont(ofSize: Theme.Metric.transcriptSize)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = Theme.Metric.transcriptLineSpacing
        tv.font = font
        tv.textColor = Theme.nsTextBody
        tv.defaultParagraphStyle = para
        let range = NSRange(location: 0, length: (tv.string as NSString).length)
        tv.textStorage?.addAttributes(
            [.font: font, .foregroundColor: Theme.nsTextBody, .paragraphStyle: para], range: range)
        tv.toolTip = toolTip
        tv.menuActions = actions
        tv.onAction = onAction
        tv.onAddNote = onAddNote
        tv.onCorrect = onCorrect
        // New text at the same width still changes the line count.
        tv.invalidateIntrinsicContentSize()
    }
}

/// NSTextView that swaps the default editing context menu for transcript AI
/// actions and copy — all operating on the current selection (or the whole
/// line when nothing is highlighted).
final class ActionTextView: NSTextView {
    var menuActions: [TranscriptAction] = []
    var onAction: ((String, String) -> Void)?
    var onAddNote: ((String, Int) -> Void)?
    var onCorrect: ((TranscriptCorrectionRequest) -> Void)?
    private var lastLaidOutWidth: CGFloat = -1
    /// Where an "Add note here…" should anchor: the end of the current selection,
    /// or — with no selection — the character nearest the right-click point.
    /// Captured when the menu opens (issue #34).
    private var noteAnchorOffset = 0

    /// Height that fits the text at the current width; width stays flexible
    /// (noIntrinsicMetric) so the view fills the transcript column. SwiftUI reads
    /// this for the row height, so it always matches the drawn wrap (issue #12).
    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let container = textContainer else {
            return super.intrinsicContentSize
        }
        lm.ensureLayout(for: container)
        return NSSize(
            width: NSView.noIntrinsicMetric, height: ceil(lm.usedRect(for: container).height))
    }

    // Whenever SwiftUI gives us a new width (window resize, session switch,
    // sidebar reflow) the container has already tracked to it via super, so the
    // freshly invalidated intrinsic height reflects the new wrap. Guarded on a
    // real width change to avoid a layout loop.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(newSize.width - lastLaidOutWidth) > 0.5 {
            lastLaidOutWidth = newSize.width
            invalidateIntrinsicContentSize()
        }
    }

    /// Highlighted substring, or the whole line when the selection is empty.
    private var effectiveSelection: String {
        let range = selectedRange()
        let ns = string as NSString
        return range.length > 0 ? ns.substring(with: range) : string
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        // Anchor a note at the selection's end, or — nothing selected — the
        // character nearest the click, so it lands right at the text in view.
        let range = selectedRange()
        noteAnchorOffset = range.length > 0
            ? range.location + range.length
            : characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let selection = effectiveSelection
        let label = selection.count > 40 ? String(selection.prefix(40)) + "…" : selection
        for action in menuActions {
            let item = NSMenuItem(
                title: "\(action.title): “\(label)”",
                action: #selector(performAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.kind
            menu.addItem(item)
        }
        if !menuActions.isEmpty { menu.addItem(.separator()) }

        // Add an editorial note here (issue #34): always available where wired
        // (the live feed), with no selection needed — it anchors to this line.
        if onAddNote != nil {
            let note = NSMenuItem(
                title: "Add note here…", action: #selector(addNoteHere(_:)), keyEquivalent: "")
            note.target = self
            menu.addItem(note)
            menu.addItem(.separator())
        }

        // Correction (issue #32): only on a real highlight, and only where a
        // handler is wired (live feed + saved non-live notes).
        if onCorrect != nil, selectedRange().length > 0 {
            let correct = NSMenuItem(
                title: "Correct “\(label)”…", action: #selector(correctThisOccurrence(_:)),
                keyEquivalent: "")
            correct.target = self
            menu.addItem(correct)
            let all = NSMenuItem(
                title: "Replace all “\(label)”…", action: #selector(correctAllOccurrences(_:)),
                keyEquivalent: "")
            all.target = self
            menu.addItem(all)
            menu.addItem(.separator())
        }

        let copy = NSMenuItem(title: "Copy", action: #selector(copyText(_:)), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        return menu
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? String else { return }
        let selection = effectiveSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.isEmpty else { return }
        onAction?(kind, selection)
    }

    @objc private func addNoteHere(_ sender: NSMenuItem) {
        guard let text = promptForNote(), !text.isEmpty else { return }
        onAddNote?(text, noteAnchorOffset)
    }

    /// Multiline text prompt for an editorial note (issue #34). Nil on cancel.
    private func promptForNote() -> String? {
        let alert = NSAlert()
        alert.messageText = "Add note"
        alert.informativeText = "Your own context for this point — the agents will read it."
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 72))
        field.font = NSFont.systemFont(ofSize: 13)
        field.isRichText = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 72))
        scroll.documentView = field
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func correctThisOccurrence(_ sender: NSMenuItem) {
        beginCorrection(scope: .thisOccurrence)
    }

    @objc private func correctAllOccurrences(_ sender: NSMenuItem) {
        beginCorrection(scope: .allInSession)
    }

    /// Resolve the highlighted span to a correction request and prompt for the
    /// replacement. The selected text is trimmed of surrounding whitespace, and
    /// its paragraph-local occurrence index is taken from where the trimmed text
    /// starts — so the same word selected twice still pins the right instance.
    private func beginCorrection(scope: TranscriptCorrectionRequest.Scope) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        let raw = (string as NSString).substring(with: range)
        let leading = raw.prefix { $0 == " " || $0 == "\t" || $0 == "\n" }.count
        let original = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return }
        let occurrence = TranscriptCorrection.occurrenceIndex(
            of: original, before: range.location + leading, in: string)
        guard let replacement = promptForReplacement(of: original), replacement != original
        else { return }
        onCorrect?(
            TranscriptCorrectionRequest(
                original: original, replacement: replacement,
                occurrenceInParagraph: occurrence, scope: scope))
    }

    /// Modal text prompt prefilled with the word being corrected. Nil on cancel.
    private func promptForReplacement(of original: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Correct transcription"
        alert.informativeText = "Replace “\(original)” with:"
        let field = NSTextField(string: original)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Correct")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    @objc private func copyText(_ sender: NSMenuItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(effectiveSelection, forType: .string)
    }
}
