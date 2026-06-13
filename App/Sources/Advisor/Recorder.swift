import Foundation
import Synchronization

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
    /// True while listening but audio is paused (engines idle, no new input).
    @Published var paused = false
    /// True while the local mic is muted (system audio still captured).
    @Published var micMuted = false
    @Published var status = "idle"
    /// Cards from the sidecar, newest first.
    @Published var cards: [Card] = []
    /// Cumulative LLM cost for the current session (USD).
    @Published var costUsd: Double = 0
    /// Live in-progress speech (volatile STT results), per source.
    @Published var volatile: [Source: String] = [:]
}

enum STTEngine: String {
    case whisper
    case apple
}

/// Wires capture → transcription (whisper or Apple) → dedup → store.
final class Recorder {
    private let capture = AudioCapture()
    private let systemCapture = SystemAudioCapture()
    private let micSegmenter = Segmenter()
    private let sysSegmenter = Segmenter()
    private let engine: STTEngine
    private let transcriber: WhisperTranscriber? // whisper engine only
    private let appleMic: AppleSpeechEngine?
    private let appleSys: AppleSpeechEngine?
    private let store: TranscriptStore
    private let whisperQueue = DispatchQueue(label: "advisor.whisper")
    // These flags are read on the realtime audio/sysaudio capture threads and
    // written from the control path (start/stop/pause/mute), so they are atomic
    // to avoid a data race. Relaxed ordering: each is independent, no flag guards
    // another's visibility.
    private let systemActive = Atomic<Bool>(false)
    /// When true, capture callbacks drop audio so no new transcription occurs.
    private let paused = Atomic<Bool>(false)
    /// When true, mic callbacks drop audio (system audio keeps flowing).
    private let micMuted = Atomic<Bool>(false)
    /// Recent `them` utterances for echo dedup. Only touched on whisperQueue.
    private var recentThem: [(time: Date, tokens: [String])] = []
    /// Called on the main actor for each accepted utterance.
    var onUtterance: ((Utterance) -> Void)?

    /// Update the STT vocabulary bias (whisper engine only; Apple STT has no
    /// equivalent hook in v1).
    func setVocabulary(_ vocab: String) {
        whisperQueue.async { self.transcriber?.setVocabulary(vocab) }
    }

    init(store: TranscriptStore, modelPath: String, engine: STTEngine, locale: String) throws {
        self.store = store
        self.engine = engine
        switch engine {
        case .whisper:
            transcriber = try WhisperTranscriber(modelPath: modelPath)
            appleMic = nil
            appleSys = nil
        case .apple:
            transcriber = nil
            appleMic = AppleSpeechEngine(name: "mic", locale: locale)
            appleSys = AppleSpeechEngine(name: "sys", locale: locale)
        }

        micSegmenter.onSegment = { [weak self] in self?.handleSegment($0, from: .me) }
        sysSegmenter.onSegment = { [weak self] in self?.handleSegment($0, from: .them) }
        appleMic?.onFinal = { [weak self] text in self?.acceptAsync(text, from: .me) }
        appleSys?.onFinal = { [weak self] text in self?.acceptAsync(text, from: .them) }
        appleMic?.onVolatile = { [weak self] text in self?.setVolatile(text, for: .me) }
        appleSys?.onVolatile = { [weak self] text in self?.setVolatile(text, for: .them) }

        capture.onSamples = { [weak self] samples in
            guard let self,
                !self.paused.load(ordering: .relaxed),
                !self.micMuted.load(ordering: .relaxed) else { return }
            switch self.engine {
            case .whisper: self.micSegmenter.append(samples)
            case .apple: self.appleMic?.append(samples)
            }
        }
        systemCapture.onSamples = { [weak self] samples in
            guard let self, !self.paused.load(ordering: .relaxed) else { return }
            switch self.engine {
            case .whisper: self.sysSegmenter.append(samples)
            case .apple: self.appleSys?.append(samples)
            }
        }
        systemCapture.onStopped = { [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                self.store.status = "system audio stopped: \(error.map(String.init(describing:)) ?? "ok")"
            }
        }
    }

    // Incremented on the capture thread, decremented on whisperQueue — atomic so
    // the cross-thread arithmetic can't lose updates.
    private let queueDepth = Atomic<Int>(0)

    private func handleSegment(_ segment: [Float], from source: Source) {
        let spokenEnd = Date()
        let depth = queueDepth.wrappingAdd(1, ordering: .relaxed).newValue
        FileHandle.standardError.write(
            Data("[advisor] segment(\(source)): \(Float(segment.count) / 16_000)s queue=\(depth)\n".utf8))
        // `me` is delayed so the matching `them` segment (same speech via the
        // speakers) is transcribed first and can be matched by the echo check
        // (system segments cap at 5 s, so 4 s covers most boundary skew).
        let delay: TimeInterval = source == .me && systemActive.load(ordering: .relaxed) ? 4.0 : 0
        whisperQueue.asyncAfter(deadline: .now() + delay) {
            // Back-pressure: if we're lagging badly, drop rather than replay a backlog.
            if Date().timeIntervalSince(spokenEnd) > 20 {
                self.queueDepth.wrappingAdd(-1, ordering: .relaxed)
                FileHandle.standardError.write(
                    Data("[advisor] skipped stale segment(\(source)) — lagging\n".utf8))
                return
            }
            guard let transcriber = self.transcriber else { return }
            let decodeStart = Date()
            let text = transcriber.transcribe(segment)
            self.queueDepth.wrappingAdd(-1, ordering: .relaxed)
            let decodeMs = Int(Date().timeIntervalSince(decodeStart) * 1000)
            let audioMs = segment.count / 16
            FileHandle.standardError.write(
                Data("[advisor] decode(\(source)): \(decodeMs)ms for \(audioMs)ms audio\n".utf8))
            FileHandle.standardError.write(
                Data("[advisor] whisper(\(source)): \"\(text)\"\n".utf8))
            self.accept(text, from: source, spokenEnd: spokenEnd)
        }
    }

    private func setVolatile(_ text: String, for source: Source) {
        Task { @MainActor in self.store.volatile[source] = text }
    }

    /// Entry point for engines that deliver finished text (Apple STT). Applies
    /// a short me-delay so echo dedup can see the system-audio twin first
    /// (Apple finalises both streams near-simultaneously, unlike whisper).
    private func acceptAsync(_ text: String, from source: Source) {
        let spokenEnd = Date()
        FileHandle.standardError.write(
            Data("[advisor] apple(\(source)): \"\(text)\"\n".utf8))
        Task { @MainActor in self.store.volatile[source] = nil }
        let delay: TimeInterval = source == .me && systemActive.load(ordering: .relaxed) ? 1.5 : 0
        whisperQueue.asyncAfter(deadline: .now() + delay) {
            self.accept(text, from: source, spokenEnd: spokenEnd)
        }
    }

    /// Common post-STT path: junk filter, echo dedup, store. Call on whisperQueue.
    private func accept(_ text: String, from source: Source, spokenEnd: Date) {
        guard !text.isEmpty, !Self.isJunk(text) else { return }

        let tokens = Self.tokens(text)
        switch source {
        case .them:
            // Prune here too, not only in isEcho: a system-only session (no mic
            // input) never calls isEcho, so recentThem would grow unbounded.
            let now = Date()
            recentThem.removeAll { now.timeIntervalSince($0.time) > 15 }
            recentThem.append((time: now, tokens: tokens))
        case .me:
            if systemActive.load(ordering: .relaxed), isEcho(tokens) {
                FileHandle.standardError.write(
                    Data("[advisor] echo suppressed: \"\(text)\"\n".utf8))
                return
            }
        }

        let latency = Int(Date().timeIntervalSince(spokenEnd) * 1000)
        let distinctiveSet = Set(Self.distinctive(tokens))
        Task { @MainActor in
            // Retroactive echo cleanup: a system-audio utterance supersedes any
            // recent mic utterance that was its (degraded) room echo.
            if source == .them, !distinctiveSet.isEmpty {
                self.store.utterances.removeAll { u in
                    u.source == .me
                        && spokenEnd.timeIntervalSince(u.time) < 12
                        && Self.pairMatch(
                            Set(Self.distinctive(Self.tokens(u.text))), distinctiveSet)
                }
            }
            let utterance = Utterance(
                time: spokenEnd, source: source, text: text, latencyMs: latency)
            self.store.utterances.append(utterance)
            self.onUtterance?(utterance)
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

    /// Substantial pairwise overlap of distinctive words, min-length basis —
    /// tolerant of differing segment boundaries between mic and system audio.
    nonisolated static func pairMatch(_ a: Set<String>, _ b: Set<String>) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        let shared = a.intersection(b).count
        return Float(shared) / Float(min(a.count, b.count)) >= 0.7
    }

    /// True when the utterance substantially overlaps a recent `them` utterance.
    private func isEcho(_ tokens: [String]) -> Bool {
        let mine = Set(Self.distinctive(tokens))
        guard !mine.isEmpty else { return true } // nothing distinctive — junk
        let now = Date()
        recentThem.removeAll { now.timeIntervalSince($0.time) > 15 }
        return recentThem.contains { entry in
            Self.pairMatch(mine, Set(Self.distinctive(entry.tokens)))
        }
    }

    func start(device: InputDevice?, captureSystem: Bool) async {
        guard await AudioCapture.requestPermission() else {
            await MainActor.run { store.status = "microphone permission denied" }
            return
        }
        if engine == .apple {
            do {
                await MainActor.run { store.status = "starting Apple speech engine…" }
                try await appleMic?.start()
                try await appleSys?.start()
            } catch {
                await MainActor.run { store.status = "Apple STT failed: \(error)" }
                return
            }
        }
        var notes: [String] = []
        if captureSystem {
            do {
                try await systemCapture.start()
                systemActive.store(true, ordering: .relaxed)
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
                systemActive.load(ordering: .relaxed) ? "+ system audio" : nil,
            ]
            .compactMap { $0 }.joined(separator: " ")
            let status = ([detail] + notes).joined(separator: " | ")
            paused.store(false, ordering: .relaxed)
            await MainActor.run {
                store.listening = true
                store.paused = false
                store.status = status
            }
        } catch {
            await stopSystem()
            await MainActor.run { store.status = "error: \(error)" }
        }
    }

    func stop() {
        paused.store(false, ordering: .relaxed)
        micMuted.store(false, ordering: .relaxed)
        capture.stop()
        micSegmenter.flush()
        sysSegmenter.flush()
        Task {
            await appleMic?.stop()
            await appleSys?.stop()
            await stopSystem()
            await MainActor.run {
                store.listening = false
                store.paused = false
                store.micMuted = false
                store.status = "idle"
                store.volatile = [:]
            }
        }
    }

    /// Pause/resume input. Engines stay alive; paused simply drops incoming
    /// audio so no new transcription is produced. Flushes pending segments on
    /// pause so they aren't held mid-utterance.
    func pause() {
        guard !paused.load(ordering: .relaxed) else { return }
        paused.store(true, ordering: .relaxed)
        micSegmenter.flush()
        sysSegmenter.flush()
        Task { @MainActor in
            store.paused = true
            store.status = "paused"
            store.volatile = [:]
        }
    }

    func resume() {
        guard paused.load(ordering: .relaxed) else { return }
        paused.store(false, ordering: .relaxed)
        Task { @MainActor in
            store.paused = false
            store.status = "listening"
        }
    }

    /// Mute/unmute the local mic. System audio keeps being captured and
    /// transcribed. Flushes the pending mic segment on mute.
    func setMicMuted(_ muted: Bool) {
        guard micMuted.load(ordering: .relaxed) != muted else { return }
        micMuted.store(muted, ordering: .relaxed)
        if muted { micSegmenter.flush() }
        Task { @MainActor in
            store.micMuted = muted
            store.volatile[.me] = nil
        }
    }

    private func stopSystem() async {
        guard systemActive.load(ordering: .relaxed) else { return }
        systemActive.store(false, ordering: .relaxed)
        await systemCapture.stop()
    }
}
