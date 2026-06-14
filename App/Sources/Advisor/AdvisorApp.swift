import AppKit
import SwiftUI

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
    @StateObject private var store = TranscriptStore()

    var body: some Scene {
        WindowGroup("Advisor") {
            TranscriptView(store: store)
                .frame(minWidth: 420, minHeight: 480)
        }
        Settings {
            PreferencesView()
        }
    }
}

struct TranscriptView: View {
    @ObservedObject var store: TranscriptStore
    @State private var recorder: Recorder?
    @State private var fatalError: String?
    @State private var devices: [InputDevice] = []
    @State private var selectedDevice: InputDevice?
    @AppStorage("captureSystem") private var captureSystem = true
    @State private var sidecar: SidecarManager?
    @State private var queryText = ""
    /// The session prompt: optional free-text context. Filled before Listen
    /// (sent on session_start) or edited live during the session (pushed via
    /// onChange). Cleared when the session stops.
    @State private var sessionContext = ""
    @State private var triggers = AdvisorConfig.Triggers()
    @State private var autoCards = true
    @State private var pinned = false
    /// When the current session started — drives the toolbar timer. Nil when idle.
    /// Shifted forward by each pause's duration so the timer excludes pauses.
    @State private var sessionStart: Date?
    /// When paused, the moment of pausing — freezes the timer. Nil when running.
    @State private var pausedAt: Date?
    @State private var writer: SessionWriter?
    @State private var spaceMonitor: Any?
    @AppStorage("agentLanes") private var agentLanes = 3
    @AppStorage("micDeviceName") private var micDeviceName = ""

    var body: some View {
        VStack(spacing: 0) {
            ListeningToolbar(
                store: store,
                sessionStart: sessionStart,
                pausedAt: pausedAt,
                selectedDevice: $selectedDevice,
                devices: devices,
                captureSystem: captureSystem,
                sessionContext: $sessionContext,
                autoCards: $autoCards,
                pinned: $pinned,
                onPlay: { Task { await toggle() } },
                onPauseResume: { if store.paused { resumeSession() } else { pauseSession() } },
                onMuteToggle: { recorder?.setMicMuted(!store.micMuted) },
                onStop: { Task { await toggle() } },
                onSessions: {
                    if let writer { NSWorkspace.shared.open(writer.sessionsDirectory) }
                }
            )
            statusLine
            transcriptArea
            AskBar(
                text: $queryText,
                onSubmit: submitQuery
            )
        }
        .background(Theme.surfaceWindow)
        .task { setup() }
        .onAppear(perform: installSpaceMonitor)
        .onDisappear {
            if let spaceMonitor { NSEvent.removeMonitor(spaceMonitor) }
            spaceMonitor = nil
        }
        .onChange(of: selectedDevice) { _, d in if let d { micDeviceName = d.name } }
        .onChange(of: sessionContext) { _, new in
            // Push live edits to the running agents; pre-session text rides along
            // on session_start instead.
            if store.listening {
                sidecar?.sendSessionContext(new.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        .onChange(of: autoCards) { _, on in sidecar?.sendAuto(on) }
        .onChange(of: pinned) { _, on in
            guard let window = NSApp.windows.first(where: \.isVisible) else { return }
            window.level = on ? .floating : .normal
            window.collectionBehavior = on ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
        }
        .onReceive(NotificationCenter.default.publisher(for: .advisorConfigChanged)) { _ in
            // Preference toggles for triggers must reflect in the right-click
            // action menu immediately, not only after a relaunch.
            triggers = AdvisorConfig.load().triggers
        }
        .onChange(of: store.utterances) { _, _ in writer?.noteChanged() }
        // Only re-write the session note when output-bearing fields change — not
        // on pure UI toggles like expand/collapse (which also mutate store.cards).
        .onChange(of: cardsWriterKey) { _, _ in writer?.noteChanged() }
        .onChange(of: agentLanes) { _, n in sidecar?.sendLanes(n) }
    }

    /// Crash/error feedback, shown as a slim line under the toolbar only when
    /// there's something worth surfacing — normal idle/ready chatter is hidden.
    @ViewBuilder private var statusLine: some View {
        let text = fatalError ?? store.status
        if shouldShowStatus(text) {
            HStack(spacing: 6) {
                Circle()
                    .fill(store.listening
                        ? (store.paused ? Color.orange : Theme.recordRed) : Theme.textMuted)
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
    /// the gap to the previous line exceeds 1s, or when a card interrupts.
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
                if let last = buf.last, u.time.timeIntervalSince(last.time) > 1 { flush() }
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
                                    sidecar?.sendAction(
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
                                    if card.isResearching { sidecar?.sendCancel(card.id) }
                                    store.dismissCard(card.id)
                                },
                                onCancel: { sidecar?.sendCancel(card.id) },
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
        let sent = sidecar?.sendCardReply(
            cardId: card.id, kind: card.kind, title: card.title,
            base: base, replyText: reply, transcript: recentTranscript()) ?? false
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
        triggers = AdvisorConfig.load().triggers
        devices = AudioDevices.inputs()
        // Sticky mic: restore the previously chosen device by name.
        selectedDevice =
            devices.first { $0.name == micDeviceName } ?? AudioDevices.preferred(devices)
        let manager = SidecarManager(store: store)
        manager.start()
        manager.sendLanes(agentLanes)
        sidecar = manager
        writer = SessionWriter(store: store)
        rebuildRecorder()
    }

    /// Capture the live sidecar/recorder/writer so `applicationShouldTerminate`
    /// can shut them down cleanly before `_exit`. Re-run whenever any is rebuilt.
    private func registerTerminationCleanup() {
        AppDelegate.shared?.onTerminate = { [sidecar, recorder, writer] in
            recorder?.stop() // stops audio engine + ScreenCaptureKit stream
            sidecar?.stop() // closes stdin so the node child exits
            writer?.end() // synchronous final flush
        }
    }

    private func rebuildRecorder() {
        guard let manager = sidecar else { return }
        do {
            recorder = try Recorder(
                store: store, locale: AdvisorConfig.load().sttLocale)
            recorder?.onUtterance = { manager.sendUtterance($0) }
            store.status = "ready — Apple speech"
            fatalError = nil
        } catch {
            fatalError = "\(error)"
        }
        registerTerminationCleanup()
    }

    /// Space toggles play/pause/resume globally, except while editing a text
    /// field (where space must type a space). SwiftUI's `.keyboardShortcut`
    /// can't express that exception, so use a local key monitor instead.
    private func installSpaceMonitor() {
        guard spaceMonitor == nil else { return }
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            else { return event }
            // Don't steal space from a focused *editable* text field (the Ask
            // box). The selectable transcript is a non-editable NSTextView and
            // must still toggle play/pause when it holds focus.
            if let tv = event.window?.firstResponder as? NSTextView, tv.isEditable { return event }
            if !store.listening {
                Task { await toggle() }
            } else if store.paused {
                resumeSession()
            } else {
                pauseSession()
            }
            return nil
        }
    }

    /// Pause capture and freeze the timer at this moment.
    private func pauseSession() {
        guard store.listening, !store.paused else { return }
        pausedAt = Date()
        recorder?.pause()
    }

    /// Resume capture; shift `sessionStart` forward by the paused span so the
    /// timer continues from where it froze.
    private func resumeSession() {
        guard let pausedAt else { recorder?.resume(); return }
        if let start = sessionStart {
            sessionStart = start.addingTimeInterval(Date().timeIntervalSince(pausedAt))
        }
        self.pausedAt = nil
        recorder?.resume()
    }

    private func submitQuery() {
        let text = queryText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        sidecar?.sendQuery(text)
        queryText = ""
    }

    private func toggle() async {
        guard let recorder else { return }
        if store.listening {
            recorder.stop()
            sidecar?.sendSessionEnd()
            writer?.end()
            sessionContext = "" // blank slate for the next session
            sessionStart = nil
            pausedAt = nil
        } else {
            store.utterances = []
            store.cards = []
            sessionStart = Date()
            pausedAt = nil
            let ctx = sessionContext.trimmingCharacters(in: .whitespacesAndNewlines)
            sidecar?.sendSessionStart(UUID().uuidString, context: ctx)
            writer?.start()
            await recorder.start(device: selectedDevice, captureSystem: captureSystem)
        }
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
        // Transcript body type: 14.5 pt, line-height 1.68, semantic body colour.
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
