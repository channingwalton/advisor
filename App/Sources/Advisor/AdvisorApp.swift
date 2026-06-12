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
    @State private var captureSystem = true
    @State private var sidecar: SidecarManager?
    @State private var queryText = ""
    @State private var autoCards = true
    @State private var pinned = false
    @State private var writer: SessionWriter?
    @StateObject private var vocabulary = VocabularyStore()
    @State private var showDictionary = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(store.listening ? "Stop" : "Listen") {
                    Task { await toggle() }
                }
                .keyboardShortcut(.space, modifiers: [])
                Picker("Mic", selection: $selectedDevice) {
                    ForEach(devices) { d in
                        Text(d.label).tag(Optional(d))
                    }
                }
                .frame(maxWidth: 230)
                .disabled(store.listening)
                Toggle("System audio", isOn: $captureSystem)
                    .toggleStyle(.checkbox)
                    .disabled(store.listening)
                Toggle("Auto cards", isOn: $autoCards)
                    .toggleStyle(.checkbox)
                    .onChange(of: autoCards) { _, on in sidecar?.sendAuto(on) }
                Toggle("Pin", isOn: $pinned)
                    .toggleStyle(.checkbox)
                    .onChange(of: pinned) { _, on in
                        guard let window = NSApp.windows.first(where: \.isVisible) else { return }
                        window.level = on ? .floating : .normal
                        window.collectionBehavior =
                            on ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
                    }
                Circle()
                    .fill(store.listening ? .red : .gray)
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
                Button("Dictionary") { showDictionary = true }
                    .controlSize(.small)
                    .popover(isPresented: $showDictionary) {
                        DictionaryView(vocabulary: vocabulary)
                    }
                if store.listening {
                    LevelMeter(label: "mic", level: store.inputLevel)
                    if captureSystem {
                        LevelMeter(label: "sys", level: store.systemLevel)
                    }
                }
            }
            .padding(10)
            Divider()
            VSplitView {
                cardsPane
                transcriptPane
            }
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
        .onChange(of: store.utterances) { _, _ in writer?.noteChanged() }
        .onChange(of: store.cards) { _, _ in writer?.noteChanged() }
    }

    private var cardsPane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if store.cards.isEmpty {
                    Text("Answers appear here — ask below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.cards) { card in
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
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 150)
    }

    private var transcriptPane: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(store.utterances) { u in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(u.source.rawValue)
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(
                                            u.source == .me ? Color.blue.opacity(0.2) : Color.green.opacity(0.2),
                                            in: Capsule())
                                    Text(u.time, style: .time)
                                    Text("\(u.latencyMs) ms")
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                TappableWords(text: u.text, vocabulary: vocabulary)
                            }
                            .id(u.id)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: store.utterances) { _, new in
                    if let last = new.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .frame(minHeight: 120)
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
        selectedDevice = AudioDevices.preferred(devices)
        let manager = SidecarManager(store: store)
        manager.start()
        sidecar = manager
        writer = SessionWriter(store: store)
        let modelPath =
            ProcessInfo.processInfo.environment["ADVISOR_WHISPER_MODEL"] ?? defaultModelPath
        do {
            recorder = try Recorder(store: store, modelPath: modelPath)
            recorder?.onUtterance = { manager.sendUtterance($0) }
            vocabulary.onChange = { [weak recorder = recorder] vocab in
                recorder?.setVocabulary(vocab)
            }
            recorder?.setVocabulary(vocabulary.joined) // include system spelling terms
            store.status = "ready — model: \((modelPath as NSString).lastPathComponent)"
        } catch {
            fatalError = "\(error)"
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
