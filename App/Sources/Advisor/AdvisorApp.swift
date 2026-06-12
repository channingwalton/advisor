import AppKit
import AVFoundation
import SwiftUI

let defaultModelPath =
    "/Users/channing/dev/advisor/Advisor/vendor/whisper.cpp/models/ggml-large-v3-turbo.bin"

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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

struct LevelMeter: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 4) {
            Text(level < 0.0005 ? "\(label): SILENT" : String(format: "\(label): %.3f", level))
                .font(.caption2.monospaced())
                .foregroundStyle(level < 0.0005 ? Color.red : .secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(level > 0.006 ? Color.green : Color.orange)
                        .frame(width: geo.size.width * CGFloat(min(1, level * 8)))
                }
            }
            .frame(width: 80, height: 8)
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
                if store.listening {
                    LevelMeter(label: "mic", level: store.inputLevel)
                    if captureSystem {
                        LevelMeter(label: "sys", level: store.systemLevel)
                    }
                }
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
    }

    /// Transcript and cards merged chronologically, so answers appear in context.
    private var feed: [FeedItem] {
        (store.utterances.map(FeedItem.utterance) + store.cards.map(FeedItem.card))
            .sorted { $0.time < $1.time }
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
                            Text(u.text)
                                .textSelection(.enabled)
                                .help(u.time.formatted(date: .omitted, time: .standard))
                                .contextMenu {
                                    Menu("Add to dictionary") {
                                        ForEach(dictionaryCandidates(u.text), id: \.self) { word in
                                            Button(word) { vocabulary.add(word) }
                                        }
                                    }
                                    Button("Copy sentence") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(u.text, forType: .string)
                                    }
                                }
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
                }
            }
            Text(LocalizedStringKey(card.body))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
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
    }

    /// Space toggles play/pause/resume globally, except while editing a text
    /// field (where space must type a space). SwiftUI's `.keyboardShortcut`
    /// can't express that exception, so use a local key monitor instead.
    private func installSpaceMonitor() {
        guard spaceMonitor == nil else { return }
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            else { return event }
            // Don't steal space from a focused text field.
            if event.window?.firstResponder is NSTextView { return event }
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
