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

    private var queueDepth = 0 // approximate; updated on whisperQueue

    private func handleSegment(_ segment: [Float], from source: Source) {
        let spokenEnd = Date()
        queueDepth += 1
        FileHandle.standardError.write(
            Data("[advisor] segment(\(source)): \(Float(segment.count) / 16_000)s queue=\(queueDepth)\n".utf8))
        // `me` is delayed so the matching `them` segment (same speech via the
        // speakers) is transcribed first and can be matched by the echo check.
        let delay: TimeInterval = source == .me && systemActive ? 1.0 : 0
        whisperQueue.asyncAfter(deadline: .now() + delay) {
            // Back-pressure: if we're lagging badly, drop rather than replay a backlog.
            if Date().timeIntervalSince(spokenEnd) > 20 {
                self.queueDepth -= 1
                FileHandle.standardError.write(
                    Data("[advisor] skipped stale segment(\(source)) — lagging\n".utf8))
                return
            }
            let decodeStart = Date()
            let text = self.transcriber.transcribe(segment)
            self.queueDepth -= 1
            let decodeMs = Int(Date().timeIntervalSince(decodeStart) * 1000)
            let audioMs = segment.count / 16
            FileHandle.standardError.write(
                Data("[advisor] decode(\(source)): \(decodeMs)ms for \(audioMs)ms audio\n".utf8))
            FileHandle.standardError.write(
                Data("[advisor] whisper(\(source)): \"\(text)\"\n".utf8))
            guard !text.isEmpty, !Self.isJunk(text) else { return }

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

    /// Whisper non-speech artefacts: "[BLANK_AUDIO]", "*Bell rings*", "(claps)", lone punctuation.
    private static func isJunk(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.rangeOfCharacter(from: .alphanumerics) == nil { return true }
        if let first = t.first, let last = t.last,
            "([*".contains(first), ")]*".contains(last) {
            return true
        }
        return false
    }

    /// Distinctive tokens only — stopword-length words inflate echo matches
    /// and caused genuine speech to be suppressed.
    private static func distinctive(_ tokens: [String]) -> [String] {
        tokens.filter { $0.count > 3 }
    }

    /// True when the utterance substantially overlaps a single recent `them`
    /// utterance (compared pairwise on distinctive words, min-length basis, so
    /// differing segment boundaries between mic and system audio still match).
    private func isEcho(_ tokens: [String]) -> Bool {
        let mine = Set(Self.distinctive(tokens))
        guard !mine.isEmpty else { return true } // nothing distinctive — junk
        let now = Date()
        recentThem.removeAll { now.timeIntervalSince($0.time) > 15 }

        for entry in recentThem {
            let theirs = Set(Self.distinctive(entry.tokens))
            guard !theirs.isEmpty else { continue }
            let shared = mine.intersection(theirs).count
            let ratio = Float(shared) / Float(min(mine.count, theirs.count))
            if ratio >= 0.7 { return true }
        }
        return false
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
