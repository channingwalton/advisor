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
    /// Mutable so a transcription error can be corrected in place (issue #32)
    /// without losing the line's identity, time, or source.
    var text: String
    let latencyMs: Int
}

/// A note the user injected into the transcript by hand (issue #34): their own
/// context the audio missed or got wrong. Rendered as a distinct (green) card,
/// anchored at `time` so it sorts into the feed where the user added it, and fed
/// to the agents as part of the transcript stream.
struct EditorialNote: Identifiable, Equatable {
    let id: UUID
    /// Anchor time — the selected line's time, so the note sorts into place
    /// directly under the text the user was looking at.
    let time: Date
    var text: String
}

/// Maps a character offset within a rendered transcript paragraph back to the
/// utterance it falls in, so an editorial note anchors at the *selected line*
/// (issue #34) rather than the paragraph's end. The paragraph text the view
/// shows is the run's utterances joined by single spaces, so offsets advance by
/// each line's UTF-16 length plus one for the separator.
enum NoteAnchor {
    static func time(forOffset offset: Int, in utterances: [(text: String, time: Date)]) -> Date? {
        var cursor = 0
        for u in utterances {
            let len = (u.text as NSString).length
            // `<=` so the trailing separator/caret position counts as this line.
            if offset <= cursor + len { return u.time }
            cursor += len + 1
        }
        return utterances.last?.time
    }
}

@MainActor
final class TranscriptStore: ObservableObject {
    @Published var utterances: [Utterance] = []
    @Published var listening = false
    /// True while the local mic is muted (system audio still captured).
    @Published var micMuted = false
    @Published var status = "idle"
    /// Cards from the sidecar, newest first.
    @Published var cards: [Card] = []
    /// Editorial notes the user injected into the transcript (issue #34).
    @Published var notes: [EditorialNote] = []
    /// Live in-progress speech (volatile STT results), per source.
    @Published var volatile: [Source: String] = [:]
    /// Bumped on every session start. STT results carry the generation of the
    /// session that produced them; a store write is dropped when it no longer
    /// matches, so a previous session's trailing/echo-delayed finals can't bleed
    /// into the next one — even when the recorder is reused (fast Stop→Listen) or
    /// a fresh recorder writes to this same shared store (close→reopen).
    var sessionGeneration = 0

    /// Expand/collapse a card in place.
    func toggleCard(_ id: String) {
        guard let idx = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[idx].isExpanded.toggle()
    }

    /// Remove a card from the stream.
    func dismissCard(_ id: String) {
        cards.removeAll { $0.id == id }
    }

    /// Inject an editorial note at `time` (the anchor line's time, so it sorts
    /// into the feed where the user added it). Trims whitespace; blank text is
    /// ignored. Returns the stored note so the caller can forward it to the
    /// sidecar under the same id, or nil when there was nothing to add.
    @discardableResult
    func addNote(_ text: String, at time: Date) -> EditorialNote? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let note = EditorialNote(id: UUID(), time: time, text: trimmed)
        notes.append(note)
        return note
    }

    /// Remove an editorial note (issue #34). The note already consumed by the
    /// agents stays in their context — like a transcript correction, removal is
    /// display/persistence only, never re-sent to the sidecar.
    func dismissNote(_ id: UUID) {
        notes.removeAll { $0.id == id }
    }

    /// Correct a transcription error in place (issue #32): replace the
    /// `occurrence`-th match (0-based, within the displayed paragraph) of
    /// `original` with `replacement`, across the run of utterances
    /// `utteranceIds` that composes that paragraph, in document order. Text-only —
    /// the line keeps its id/time/source and nothing is re-sent to the sidecar;
    /// the session writer's debounced rewrite persists the edited text.
    func correctOccurrence(
        _ occurrence: Int, of original: String, with replacement: String,
        inParagraph utteranceIds: [UUID]
    ) {
        let indices = utteranceIds.compactMap { id in utterances.firstIndex { $0.id == id } }
        let texts = indices.map { utterances[$0].text }
        guard
            let updated = TranscriptCorrection.replacingOccurrence(
                occurrence, of: original, with: replacement, in: texts)
        else { return }
        for (slot, index) in indices.enumerated() where updated[slot] != texts[slot] {
            utterances[index].text = updated[slot]
        }
    }

    /// Correct every occurrence of `original` across the whole session's
    /// transcript (issue #32). Text-only, like `correctOccurrence`.
    func correctAll(of original: String, with replacement: String) {
        guard !original.isEmpty else { return }
        for index in utterances.indices {
            let corrected = utterances[index].text.replacingOccurrences(
                of: original, with: replacement)
            if corrected != utterances[index].text { utterances[index].text = corrected }
        }
    }
}

/// Wires capture → Apple speech transcription → dedup → store.
final class Recorder {
    private let capture = AudioCapture()
    private let systemCapture = SystemAudioCapture()
    private let appleMic: AppleSpeechEngine
    private let appleSys: AppleSpeechEngine
    private let store: TranscriptStore
    private let sttQueue = DispatchQueue(label: "advisor.stt")
    // These flags are read on the realtime audio/sysaudio capture threads and
    // written from the control path (start/stop/mute), so they are atomic to
    // avoid a data race. Relaxed ordering: each is independent, no flag guards
    // another's visibility.
    private let systemActive = Atomic<Bool>(false)
    /// When true, mic callbacks drop audio (system audio keeps flowing).
    private let micMuted = Atomic<Bool>(false)
    /// Recent `them` utterances for echo dedup. Only touched on sttQueue.
    private var recentThem: [(time: Date, tokens: [String])] = []
    /// Called on the main actor for each accepted utterance.
    var onUtterance: ((Utterance) -> Void)?

    init(store: TranscriptStore, locale: String) throws {
        self.store = store
        appleMic = AppleSpeechEngine(name: "mic", locale: locale)
        appleSys = AppleSpeechEngine(name: "sys", locale: locale)

        // The engine tags each result with the session token it was started with,
        // so a result from a superseded session is dropped at the store write.
        appleMic.onFinal = { [weak self] text, gen in self?.acceptAsync(text, from: .me, gen: gen) }
        appleSys.onFinal = { [weak self] text, gen in self?.acceptAsync(text, from: .them, gen: gen) }
        appleMic.onVolatile = { [weak self] text, gen in self?.setVolatile(text, for: .me, gen: gen) }
        appleSys.onVolatile = { [weak self] text, gen in self?.setVolatile(text, for: .them, gen: gen) }

        capture.onSamples = { [weak self] samples in
            guard let self, !self.micMuted.load(ordering: .relaxed) else { return }
            self.appleMic.append(samples)
        }
        systemCapture.onSamples = { [weak self] samples in
            self?.appleSys.append(samples)
        }
        systemCapture.onStopped = { [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    self.store.status = SystemAudioCapture.startFailureNote(for: error)
                } else {
                    self.store.status = "system audio stopped: ok"
                }
            }
        }
    }

    private func setVolatile(_ text: String, for source: Source, gen: Int) {
        Task { @MainActor in
            guard gen == self.store.sessionGeneration else { return }
            self.store.volatile[source] = text
        }
    }

    /// Entry point for Apple STT's finished text. Applies a short me-delay so
    /// echo dedup can see the system-audio twin first (Apple finalises both
    /// streams near-simultaneously). `gen` is the session token the result was
    /// produced under; it rides through to the store write, which drops it if the
    /// session has since moved on.
    private func acceptAsync(_ text: String, from source: Source, gen: Int) {
        let spokenEnd = Date()
        appLog.write("[advisor] apple(\(source)): \"\(text)\"")
        Task { @MainActor in
            if gen == self.store.sessionGeneration { self.store.volatile[source] = nil }
        }
        let delay: TimeInterval = source == .me && systemActive.load(ordering: .relaxed) ? 1.5 : 0
        sttQueue.asyncAfter(deadline: .now() + delay) {
            self.accept(text, from: source, spokenEnd: spokenEnd, gen: gen)
        }
    }

    /// Common post-STT path: junk filter, echo dedup, store. Call on sttQueue.
    private func accept(_ text: String, from source: Source, spokenEnd: Date, gen: Int) {
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
                appLog.write("[advisor] echo suppressed: \"\(text)\"")
                return
            }
        }

        let latency = Int(Date().timeIntervalSince(spokenEnd) * 1000)
        let distinctiveSet = Set(Self.distinctive(tokens))
        Task { @MainActor in
            // Drop the write if the session moved on while this was queued (the
            // me-delay, or the engine's post-stop flush) — the gate that keeps the
            // previous conversation out of the next session.
            guard gen == self.store.sessionGeneration else { return }
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

    /// Non-speech artefacts: "[BLANK_AUDIO]", "*Bell rings*", "(claps)", lone punctuation.
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
        // The caller bumps `sessionGeneration` synchronously before this `await`;
        // read it here and tag every result with it, so anything still in flight
        // from the previous session is dropped at the store write.
        let gen = await MainActor.run { store.sessionGeneration }
        guard await AudioCapture.requestPermission() else {
            await MainActor.run { store.status = "microphone permission denied" }
            return
        }
        do {
            await MainActor.run { store.status = "starting Apple speech engine…" }
            try await appleMic.start(sessionToken: gen)
            try await appleSys.start(sessionToken: gen)
        } catch {
            await MainActor.run { store.status = "Apple STT failed: \(error)" }
            return
        }
        var notes: [String] = []
        systemActive.store(false, ordering: .relaxed)
        if captureSystem {
            if await SystemAudioCapture.requestAccessIfNeeded() {
                do {
                    try await systemCapture.start()
                    systemActive.store(true, ordering: .relaxed)
                } catch {
                    notes.append(SystemAudioCapture.startFailureNote(for: error))
                }
            } else {
                notes.append(SystemAudioCapture.permissionRequiredNote)
            }
        }
        do {
            // AEC (voice processing) disabled: on this setup it either fails
            // to initialise (-10875, multichannel output) or mutes the mic.
            // Echo from speakers is handled downstream by text dedup instead.
            try capture.start(device: device, echoCancellation: false)
            let detail = [
                "listening — \(device?.label ?? "default input")",
                systemActive.load(ordering: .relaxed) ? "+ system audio" : nil,
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
        micMuted.store(false, ordering: .relaxed)
        capture.stop()
        Task {
            await appleMic.stop()
            await appleSys.stop()
            await stopSystem()
            await MainActor.run {
                store.listening = false
                store.micMuted = false
                store.status = "idle"
                store.volatile = [:]
            }
        }
    }

    /// Mute/unmute the local mic. System audio keeps being captured and
    /// transcribed.
    func setMicMuted(_ muted: Bool) {
        guard micMuted.load(ordering: .relaxed) != muted else { return }
        micMuted.store(muted, ordering: .relaxed)
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
