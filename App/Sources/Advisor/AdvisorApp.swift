import AppKit
import AVFoundation
import MarkdownUI
import SwiftUI

// Repo root, derived from this source file's compile-time location so the
// checkout can move without editing paths. Sources/Advisor/AdvisorApp.swift
// is four levels below the repo root (…/App/Sources/Advisor/AdvisorApp.swift).
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Advisor/
    .deletingLastPathComponent()   // Sources/
    .deletingLastPathComponent()   // App/
    .deletingLastPathComponent()   // repo root

let defaultModelPath = AppResources.defaultModelPath

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
enum Main {
    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--smoke"),
            CommandLine.arguments.count > i + 1 {
            smokeTest(wavPath: CommandLine.arguments[i + 1])
        } else {
            AdvisorApp.main()
        }
    }

    /// Headless check: model loads and transcribes a 16 kHz mono wav.
    private static func smokeTest(wavPath: String) {
        // Run in a nested scope so WhisperTranscriber deinits (whisper_free)
        // before exit() — ggml's Metal teardown asserts otherwise.
        let code = runSmoke(wavPath: wavPath)
        exit(code)
    }

    private static func runSmoke(wavPath: String) -> Int32 {
        do {
            let modelPath =
                ProcessInfo.processInfo.environment["ADVISOR_WHISPER_MODEL"] ?? defaultModelPath
            let url = URL(fileURLWithPath: wavPath)
            let file = try AVAudioFile(forReading: url)
            guard file.processingFormat.sampleRate == 16_000 else {
                print("SMOKE FAIL: expected 16 kHz wav, got \(file.processingFormat.sampleRate)")
                return 1
            }
            guard
                let buf = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: AVAudioFrameCount(file.length))
            else {
                print("SMOKE FAIL: buffer alloc")
                return 1
            }
            try file.read(into: buf)
            guard let ch = buf.floatChannelData else {
                print("SMOKE FAIL: no float data")
                return 1
            }
            let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
            let transcriber = try WhisperTranscriber(modelPath: modelPath)
            let t0 = Date()
            let text = transcriber.transcribe(samples)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("SMOKE OK (\(ms) ms): \(text)")
            return text.isEmpty ? 1 : 0
        } catch {
            print("SMOKE FAIL: \(error)")
            return 1
        }
    }
}

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
    @State private var builtEngine = ""
    @State private var queryText = ""
    @State private var triggers = AdvisorConfig.Triggers()
    @State private var autoCards = true
    @State private var pinned = false
    @State private var writer: SessionWriter?
    @State private var spaceMonitor: Any?
    @ObservedObject private var vocabulary = VocabularyStore.shared
    @AppStorage("agentLanes") private var agentLanes = 3
    @AppStorage("sttEngine") private var sttEngine = STTEngine.apple.rawValue
    @AppStorage("micDeviceName") private var micDeviceName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if store.listening {
                    Button {
                        if store.paused { recorder?.resume() } else { recorder?.pause() }
                    } label: {
                        Image(systemName: store.paused ? "play.fill" : "pause.fill")
                    }
                    .help(store.paused ? "Resume (Space)" : "Pause (Space)")
                    Button {
                        Task { await toggle() }
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .help("Stop (Esc)")
                    .keyboardShortcut(.escape, modifiers: [])
                } else {
                    Button {
                        Task { await toggle() }
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .help("Listen (Space)")
                }
                Picker("Mic", selection: $selectedDevice) {
                    ForEach(devices) { d in
                        Text(d.label).tag(Optional(d))
                    }
                }
                .frame(maxWidth: 230)
                .disabled(store.listening)
                .onChange(of: selectedDevice) { _, d in
                    if let d { micDeviceName = d.name }
                }
                Toggle("Auto cards", isOn: $autoCards)
                    .toggleStyle(.checkbox)
                    .onChange(of: autoCards) { _, on in sidecar?.sendAuto(on) }
                Toggle("Float", isOn: $pinned)
                    .toggleStyle(.checkbox)
                    .onChange(of: pinned) { _, on in
                        guard let window = NSApp.windows.first(where: \.isVisible) else { return }
                        window.level = on ? .floating : .normal
                        window.collectionBehavior =
                            on ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
                    }
                Circle()
                    .fill(store.listening ? (store.paused ? .orange : .red) : .gray)
                    .frame(width: 10, height: 10)
                Text(fatalError ?? store.status)
                    .font(.caption)
                    .foregroundStyle(fatalError == nil ? .secondary : Color.red)
                Spacer()
                if store.costUsd > 0 {
                    Text(String(format: "$%.2f", store.costUsd))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button("Sessions") {
                    if let writer { NSWorkspace.shared.open(writer.sessionsDirectory) }
                }
                .controlSize(.small)
            }
            .padding(10)
            Divider()
            feedPane
            Divider()
            HStack {
                TextField("Ask about the conversation…", text: $queryText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitQuery)
                Button("Ask", action: submitQuery)
                    .disabled(queryText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
        .task { setup() }
        .onAppear(perform: installSpaceMonitor)
        .onDisappear {
            if let spaceMonitor { NSEvent.removeMonitor(spaceMonitor) }
            spaceMonitor = nil
        }
        .onChange(of: store.utterances) { _, _ in writer?.noteChanged() }
        .onChange(of: store.cards) { _, _ in writer?.noteChanged() }
        .onChange(of: agentLanes) { _, n in sidecar?.sendLanes(n) }
        .onChange(of: sttEngine) { _, _ in
            if !store.listening { rebuildRecorder() }
        }
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

    private var feedPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if feed.isEmpty {
                        Text("Click Listen — the conversation and answer cards appear here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(feed) { item in
                        switch item {
                        case .utterance(let u):
                            SelectableTranscriptText(
                                text: u.text,
                                toolTip: u.time.formatted(date: .omitted, time: .standard),
                                actions: transcriptActions,
                                onAction: { kind, selection in
                                    sidecar?.sendAction(
                                        kind, text: selection, triggerId: u.id.uuidString)
                                },
                                dictionaryCandidates: { dictionaryCandidates(u.text) },
                                onAddWord: { vocabulary.add($0) }
                            )
                            .id(item.id)
                        case .card(let card):
                            cardView(card)
                                .id(item.id)
                        }
                    }
                    // Live in-progress speech, replaced by final sentences above.
                    ForEach(Array(store.volatile.keys), id: \.self) { source in
                        if let text = store.volatile[source], !text.isEmpty {
                            Text(text)
                                .italic()
                                .foregroundStyle(.tertiary)
                                .id("volatile-\(source.rawValue)")
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: feed.count) { _, _ in
                if let last = feed.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func cardView(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(card.kind)
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(kindColour(card.kind).opacity(0.2), in: Capsule())
                Text(card.title).font(.headline)
                Spacer()
                if card.state == "pending" || card.state == "streaming" {
                    ProgressView().controlSize(.small)
                    Button {
                        sidecar?.sendCancel(card.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Skip this card")
                } else if card.state == "failed" {
                    Text("failed").font(.caption2).foregroundStyle(.red)
                } else if card.state == "cancelled" {
                    Text("cancelled").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Markdown(card.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
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

    /// Distinct words worth adding to the STT dictionary, in sentence order.
    private func dictionaryCandidates(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: " ")
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count > 2 && !vocabulary.contains($0) && seen.insert($0.lowercased()).inserted }
    }

    private func kindColour(_ kind: String) -> Color {
        switch kind {
        case "answer": .blue
        case "context": .green
        case "factcheck": .orange
        default: .purple
        }
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
        let engine = STTEngine(rawValue: sttEngine) ?? .apple
        let modelPath =
            ProcessInfo.processInfo.environment["ADVISOR_WHISPER_MODEL"] ?? defaultModelPath
        do {
            recorder = try Recorder(
                store: store, modelPath: modelPath, engine: engine,
                locale: AdvisorConfig.load().sttLocale)
            recorder?.onUtterance = { manager.sendUtterance($0) }
            vocabulary.onChange = { [weak recorder = recorder] vocab in
                recorder?.setVocabulary(vocab)
            }
            recorder?.setVocabulary(vocabulary.joined) // include system spelling terms
            store.status =
                engine == .apple
                ? "ready — Apple speech" : "ready — \((modelPath as NSString).lastPathComponent)"
            builtEngine = engine.rawValue
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
                recorder?.resume()
            } else {
                recorder?.pause()
            }
            return nil
        }
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
            // Engine changed in preferences mid-session: apply now.
            if builtEngine != sttEngine { rebuildRecorder() }
        } else {
            store.utterances = []
            store.cards = []
            store.costUsd = 0
            sidecar?.sendSessionStart(UUID().uuidString)
            writer?.start()
            await recorder.start(device: selectedDevice, captureSystem: captureSystem)
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
    /// Words from this line worth adding to the STT dictionary (vocabulary-filtered).
    let dictionaryCandidates: () -> [String]
    let onAddWord: (String) -> Void

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
        tv.font = .preferredFont(forTextStyle: .body)
        tv.textColor = .labelColor
        tv.toolTip = toolTip
        tv.menuActions = actions
        tv.onAction = onAction
        tv.dictionaryCandidates = dictionaryCandidates
        tv.onAddWord = onAddWord
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
/// actions, the dictionary submenu, and copy — all operating on the current
/// selection (or the whole line when nothing is highlighted).
final class ActionTextView: NSTextView {
    var menuActions: [TranscriptAction] = []
    var onAction: ((String, String) -> Void)?
    var dictionaryCandidates: (() -> [String])?
    var onAddWord: ((String) -> Void)?

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

        let words = dictionaryCandidates?() ?? []
        if !words.isEmpty {
            let parent = NSMenuItem(title: "Add to dictionary", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for word in words {
                let item = NSMenuItem(
                    title: word, action: #selector(addWord(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = word
                submenu.addItem(item)
            }
            parent.submenu = submenu
            menu.addItem(parent)
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

    @objc private func addWord(_ sender: NSMenuItem) {
        if let word = sender.representedObject as? String { onAddWord?(word) }
    }

    @objc private func copyText(_ sender: NSMenuItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(effectiveSelection, forType: .string)
    }
}
