import Foundation

enum Source: String {
    case me
    case them
}

struct Utterance: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let source: Source
    let text: String
    let latencyMs: Int
}

@MainActor
final class TranscriptStore: ObservableObject {
    @Published var utterances: [Utterance] = []
    @Published var listening = false
    @Published var status = "idle"
    /// Smoothed input RMS, 0...~0.3 typical speech. 0 ⇒ mic delivering silence.
    @Published var inputLevel: Float = 0
    /// Smoothed system-audio RMS.
    @Published var systemLevel: Float = 0
    /// Cards from the sidecar, newest first.
    @Published var cards: [Card] = []
    /// Cumulative LLM cost for the current session (USD).
    @Published var costUsd: Double = 0
}

/// Wires capture → segmentation → transcription → store, for both sources.
final class Recorder {
    private let capture = AudioCapture()
    private let systemCapture = SystemAudioCapture()
    private let micSegmenter = Segmenter()
    private let sysSegmenter = Segmenter()
    private let transcriber: WhisperTranscriber
    private let store: TranscriptStore
    private let whisperQueue = DispatchQueue(label: "advisor.whisper")
    private var systemActive = false
    /// Recent `them` utterances for echo dedup. Only touched on whisperQueue.
    private var recentThem: [(time: Date, tokens: [String])] = []
    /// Called on the main actor for each accepted utterance.
    var onUtterance: ((Utterance) -> Void)?

    /// Update the STT vocabulary bias (safe to call any time).
    func setVocabulary(_ vocab: String) {
        whisperQueue.async { self.transcriber.setVocabulary(vocab) }
    }

    init(store: TranscriptStore, modelPath: String) throws {
        self.store = store
        self.transcriber = try WhisperTranscriber(modelPath: modelPath)

        micSegmenter.onSegment = { [weak self] in self?.handleSegment($0, from: .me) }
        sysSegmenter.onSegment = { [weak self] in self?.handleSegment($0, from: .them) }

        var micCounter = 0
        capture.onSamples = { [weak self] samples in
            guard let self else { return }
            self.micSegmenter.append(samples)
            micCounter += 1
            if micCounter % 5 == 0 {
                self.publishLevel(samples, system: false)
            }
        }
        var sysCounter = 0
        systemCapture.onSamples = { [weak self] samples in
            guard let self else { return }
            self.sysSegmenter.append(samples)
            sysCounter += 1
            if sysCounter % 5 == 0 {
                self.publishLevel(samples, system: true)
            }
        }
        systemCapture.onStopped = { [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                self.store.status = "system audio stopped: \(error.map(String.init(describing:)) ?? "ok")"
            }
        }
    }

    private func publishLevel(_ samples: [Float], system: Bool) {
        guard !samples.isEmpty else { return }
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        Task { @MainActor in
            if system {
                self.store.systemLevel = rms
            } else {
                self.store.inputLevel = rms
            }
        }
    }

    private func handleSegment(_ segment: [Float], from source: Source) {
        let spokenEnd = Date()
        FileHandle.standardError.write(
            Data("[advisor] segment(\(source)): \(Float(segment.count) / 16_000)s\n".utf8))
        // `me` is delayed so the matching `them` segment (same speech via the
        // speakers) is transcribed first and can be matched by the echo check.
        let delay: TimeInterval = source == .me && systemActive ? 1.0 : 0
        whisperQueue.asyncAfter(deadline: .now() + delay) {
            let text = self.transcriber.transcribe(segment)
            FileHandle.standardError.write(
                Data("[advisor] whisper(\(source)): \"\(text)\"\n".utf8))
            guard !text.isEmpty else { return }

            let tokens = Self.tokens(text)
            switch source {
            case .them:
                self.recentThem.append((time: Date(), tokens: tokens))
            case .me:
                if self.systemActive, self.isEcho(tokens) {
                    FileHandle.standardError.write(
                        Data("[advisor] echo suppressed: \"\(text)\"\n".utf8))
                    return
                }
            }

            let latency = Int(Date().timeIntervalSince(spokenEnd) * 1000)
            Task { @MainActor in
                let utterance = Utterance(
                    time: spokenEnd, source: source, text: text, latencyMs: latency)
                self.store.utterances.append(utterance)
                self.onUtterance?(utterance)
            }
        }
    }

    private static func tokens(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// True when most of the words also occur in `them` speech from the last 15 s.
    private func isEcho(_ tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return true }
        let now = Date()
        recentThem.removeAll { now.timeIntervalSince($0.time) > 15 }
        guard !recentThem.isEmpty else { return false }

        var pool: [String: Int] = [:]
        for entry in recentThem {
            for t in entry.tokens { pool[t, default: 0] += 1 }
        }
        var matched = 0
        for t in tokens where (pool[t] ?? 0) > 0 {
            matched += 1
            pool[t]! -= 1
        }
        let ratio = Float(matched) / Float(tokens.count)
        // Short utterances ("yes", "okay") legitimately repeat; require exact.
        return tokens.count >= 4 ? ratio >= 0.6 : ratio >= 0.99
    }

    func start(device: InputDevice?, captureSystem: Bool) async {
        guard await AudioCapture.requestPermission() else {
            await MainActor.run { store.status = "microphone permission denied" }
            return
        }
        var notes: [String] = []
        if captureSystem {
            do {
                try await systemCapture.start()
                systemActive = true
            } catch {
                notes.append("system audio failed: \(error.localizedDescription)")
            }
        }
        do {
            // AEC (voice processing) disabled: on this setup it either fails
            // to initialise (-10875, multichannel output) or mutes the mic.
            // Echo from speakers is handled downstream by text dedup instead.
            try capture.start(deviceID: device?.id, echoCancellation: false)
            let detail = [
                "listening — \(device?.label ?? "default input")",
                systemActive ? "+ system audio" : nil,
            ]
            .compactMap { $0 }.joined(separator: " ")
            let status = ([detail] + notes).joined(separator: " | ")
            await MainActor.run {
                store.listening = true
                store.status = status
            }
        } catch {
            await stopSystem()
            await MainActor.run { store.status = "error: \(error)" }
        }
    }

    func stop() {
        capture.stop()
        micSegmenter.flush()
        sysSegmenter.flush()
        Task {
            await stopSystem()
            await MainActor.run {
                store.listening = false
                store.status = "idle"
                store.inputLevel = 0
                store.systemLevel = 0
            }
        }
    }

    private func stopSystem() async {
        guard systemActive else { return }
        systemActive = false
        await systemCapture.stop()
    }
}
