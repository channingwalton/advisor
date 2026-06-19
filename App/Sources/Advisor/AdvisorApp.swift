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
        Settings {
            PreferencesView()
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
    @State private var triggers = AdvisorConfig.Triggers()
    /// The user's library of named, reusable contexts (issue #10) — loaded into
    /// the Context popover's Load menu. Kept in sync with Preferences via
    /// `advisorConfigChanged`; the popover's Save persists back to config.json.
    @State private var savedContexts: [SavedContext] = []
    @State private var autoCards = true
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
        }
        .onChange(of: store.utterances) { _, _ in services.writer.noteChanged() }
        // Only re-write the session note when output-bearing fields change — not
        // on pure UI toggles like expand/collapse (which also mutate store.cards).
        .onChange(of: cardsWriterKey) { _, _ in services.writer.noteChanged() }
        .onChange(of: agentLanes) { _, n in services.sidecar.sendLanes(n) }
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
                savedContexts: savedContexts,
                onSaveContext: saveContext(named:),
                autoCards: $autoCards,
                pinned: $pinned,
                onStart: { Task { await startSession() } },
                onResume: { resumeRecording() },
                onMuteToggle: { recorder?.setMicMuted(!store.micMuted) },
                onStop: { stopRecording() },
                canExport: services.writer.hasExportContent,
                onExport: exportSession
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

        var id: String {
            switch self {
            case .utterance(let u): "u-\(u.id.uuidString)"
            case .card(let c): "c-\(c.id)"
            }
        }

        var time: Date {
            switch self {
            case .utterance(let u): u.time
            case .card(let c): c.created
            }
        }

        var isUtterance: Bool {
            if case .utterance = self { return true }
            return false
        }
    }

    /// Transcript and cards merged chronologically, so answers appear in context.
    /// At equal times a card sorts after the utterance, so a card anchored to its
    /// triggering sentence renders directly beneath it.
    private var feed: [FeedItem] {
        (store.utterances.map(FeedItem.utterance) + store.cards.map(FeedItem.card))
            .sorted { a, b in
                a.time != b.time ? a.time < b.time : a.isUtterance && !b.isUtterance
            }
    }

    /// A run of consecutive utterances rendered as one flowing paragraph.
    private struct Paragraph: Identifiable {
        let id: String
        let text: String
        let toolTip: String
        /// Last utterance in the run — manual right-click cards anchor here.
        let anchorId: String
    }

    private enum RenderItem: Identifiable {
        case paragraph(Paragraph)
        case card(Card)

        var id: String {
            switch self {
            case .paragraph(let p): "p-\(p.id)"
            case .card(let c): "c-\(c.id)"
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
                        anchorId: last.id.uuidString)))
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
            }
        }
        flush()
        return items
    }

    /// Changes whenever a final line or card is added — the auto-scroll trigger
    /// (a growing paragraph keeps its id, so id-based scrolling alone misses it).
    private var scrollKey: String { "\(store.utterances.count)|\(store.cards.count)" }

    /// Centered transcript column (max-width 812): day divider, flowing
    /// paragraphs, inline cards, then the live interim line.
    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Metric.paragraphSpacing) {
                    dayDivider
                    if renderItems.isEmpty && interimText.isEmpty {
                        Text("Press Listen — the conversation and answer cards appear here.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(renderItems) { item in
                        switch item {
                        case .paragraph(let p):
                            SelectableTranscriptText(
                                text: p.text,
                                toolTip: p.toolTip,
                                actions: transcriptActions,
                                onAction: { kind, selection in
                                    services.sidecar.sendAction(
                                        kind, text: selection, triggerId: p.anchorId)
                                }
                            )
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
                        }
                    }
                    interimLine
                }
                .frame(maxWidth: Theme.Metric.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Metric.contentTopPad)
                .padding(.horizontal, Theme.Metric.contentSidePad)
                .padding(.bottom, Theme.Metric.contentBottomPad)
            }
            .onChange(of: scrollKey) { _, _ in
                if let last = renderItems.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
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

    /// Finalise the current session: stop audio, signal the sidecar, flush the
    /// note, and clear the session state. Leaves the shared sidecar running.
    /// Called when the window closes (or its "Wait"-to-close path) — Stop alone no
    /// longer ends a session, since it's now resumable (issue #6). Safe whether
    /// the session was recording or already stopped.
    private func endSession() {
        recorder?.stop()
        services.sidecar.sendSessionEnd()
        services.writer.end()
        sessionContext = "" // blank slate for the next session
        sessionName = ""
        sessionStart = nil
        stoppedAt = nil
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
        sessionStart = Date()
        stoppedAt = nil
        let ctx = sessionContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let nm = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        services.sidecar.sendSessionStart(UUID().uuidString, context: ctx)
        services.writer.start(context: ctx, name: nm)
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

/// Selectable transcript line backed by an NSTextView, so the right-click menu
/// can act on the exact highlighted span (SwiftUI's `Text` selection is opaque
/// to a `.contextMenu`). Falls back to the whole line when nothing is selected.
struct SelectableTranscriptText: NSViewRepresentable {
    let text: String
    let toolTip: String
    let actions: [TranscriptAction]
    /// (card kind, selected text) — fired when an AI action is chosen.
    let onAction: (String, String) -> Void

    func makeNSView(context: Context) -> ActionTextView {
        // Convenience init builds a TextKit stack the view *owns* (storage
        // included) — a hand-built stack would leave storage/layoutManager
        // unretained and they'd deallocate. Touching `layoutManager` forces the
        // TextKit 1 fallback so it's available for height measurement (TextKit 2
        // leaves it nil).
        let tv = ActionTextView(frame: .zero)
        _ = tv.layoutManager
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.drawsBackground = false
        tv.backgroundColor = NSColor.clear
        tv.textContainerInset = NSSize.zero
        return tv
    }

    func updateNSView(_ tv: ActionTextView, context: Context) {
        if tv.string != text { tv.string = text }
        // Transcript body type: 14.5 pt, line-height 1.2, semantic body colour.
        let font = NSFont.systemFont(ofSize: Theme.Metric.transcriptSize)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = Theme.Metric.transcriptLineSpacing
        tv.font = font
        tv.textColor = Theme.nsTextBody
        tv.defaultParagraphStyle = para
        // isRichText is false, so style the storage directly — typingAttributes
        // alone won't reflow already-set text (and height measurement reads the
        // storage's paragraph style).
        let range = NSRange(location: 0, length: (tv.string as NSString).length)
        tv.textStorage?.addAttributes(
            [.font: font, .foregroundColor: Theme.nsTextBody, .paragraphStyle: para], range: range)
        tv.toolTip = toolTip
        tv.menuActions = actions
        tv.onAction = onAction
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView tv: ActionTextView, context: Context
    ) -> CGSize? {
        guard let container = tv.textContainer, let lm = tv.layoutManager,
            let width = proposal.width, width.isFinite, width > 0
        else { return nil }
        tv.frame.size.width = width
        lm.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(lm.usedRect(for: container).height))
    }
}

/// NSTextView that swaps the default editing context menu for transcript AI
/// actions and copy — all operating on the current selection (or the whole
/// line when nothing is highlighted).
final class ActionTextView: NSTextView {
    var menuActions: [TranscriptAction] = []
    var onAction: ((String, String) -> Void)?

    /// Highlighted substring, or the whole line when the selection is empty.
    private var effectiveSelection: String {
        let range = selectedRange()
        let ns = string as NSString
        return range.length > 0 ? ns.substring(with: range) : string
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
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

    @objc private func copyText(_ sender: NSMenuItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(effectiveSelection, forType: .string)
    }
}
