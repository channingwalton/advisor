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
        lineIndex(forOffset: offset, in: utterances.map(\.text)).map { utterances[$0].time }
    }

    /// The index of the line `offset` falls in, among `texts` joined by single
    /// spaces — the last line for an offset past the end; nil when empty.
    static func lineIndex(forOffset offset: Int, in texts: [String]) -> Int? {
        var cursor = 0
        for (index, text) in texts.enumerated() {
            let len = (text as NSString).length
            // `<=` so the trailing separator/caret position counts as this line.
            if offset <= cursor + len { return index }
            cursor += len + 1
        }
        return texts.isEmpty ? nil : texts.count - 1
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
    /// the session writer's debounced rewrite persists the edited text. The
    /// occurrence was counted over the paragraph as shown, so if any of its
    /// utterances has gone since (echo cleanup while the prompt was open) the
    /// count no longer holds and nothing is changed (issue #92).
    func correctOccurrence(
        _ occurrence: Int, of original: String, with replacement: String,
        inParagraph utteranceIds: [UUID]
    ) {
        let indices = utteranceIds.compactMap { id in utterances.firstIndex { $0.id == id } }
        guard indices.count == utteranceIds.count else { return }
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

protocol MicrophoneCaptureProtocol: AnyObject, Sendable {
    var onSamples: (([Float]) -> Void)? { get set }

    func start(device: InputDevice?, echoCancellation: Bool) throws
    func stop()
}

protocol SystemAudioCaptureProtocol: AnyObject, Sendable {
    var onSamples: (([Float]) -> Void)? { get set }
    var onStopped: ((Error?) -> Void)? { get set }

    func start() async throws
    func stop() async
}

extension AudioCapture: MicrophoneCaptureProtocol, @unchecked Sendable {}
extension SystemAudioCapture: SystemAudioCaptureProtocol, @unchecked Sendable {}

/// Wires capture → Apple speech transcription → dedup → store.
final class Recorder: @unchecked Sendable {
    private let capture: any MicrophoneCaptureProtocol
    private let systemCapture: any SystemAudioCaptureProtocol
    private let appleMic: any SpeechEngineProtocol
    private let appleSys: any SpeechEngineProtocol
    private let store: TranscriptStore
    private let requestMicPermission: @Sendable () async -> Bool
    private let requestSystemAccess: @MainActor @Sendable () -> Bool
    private let sttQueue = DispatchQueue(label: "advisor.stt")
    /// Counts a final from its engine callback through echo delay and the
    /// main-actor store write, so stop cannot finish with unsaved text queued.
    private let pendingAcceptance = DispatchGroup()
    // These flags are read on the realtime audio/sysaudio capture threads and
    // written from the control path (start/stop/mute), so they are atomic to
    // avoid a data race. Relaxed ordering: each is independent, no flag guards
    // another's visibility.
    private let systemActive = Atomic<Bool>(false)
    /// When true, mic callbacks drop audio (system audio keeps flowing).
    private let micMuted = Atomic<Bool>(false)
    /// False before capture sources drain and until both speech sinks are ready.
    /// This is a fast callback-thread gate; source draining remains the teardown
    /// synchronisation boundary.
    private let samplesEnabled = Atomic<Bool>(false)
    /// Recent `them` utterances for echo dedup. Only touched on sttQueue.
    private var recentThem: [(time: Date, tokens: [String])] = []

    // Lifecycle requests are registered synchronously on the main actor, then
    // executed by one FIFO task chain. The epoch invalidates a suspended start or
    // recovery immediately; its queued successor owns any required teardown.
    @MainActor private var lifecycleTail: Task<Void, Never>?
    @MainActor private var lifecycleEpoch = 0
    @MainActor private var desiredRunning = false
    @MainActor private var stopQueued = false
    @MainActor private var pendingStopStatus = "idle"
    @MainActor private var recoveryInFlight = false
    @MainActor private var sinksMayBeActive = false
    @MainActor private var micCaptureActive = false
    @MainActor private var speechRunToken = 0
    @MainActor private var listeningStatus = "listening"
    @MainActor private var currentDevice: InputDevice?
    /// Called on the main actor for each accepted utterance.
    var onUtterance: ((Utterance) -> Void)?
    /// Whether recognised text goes into the log file (the `logTranscriptText`
    /// preference, set from the main actor whenever it changes, read on the STT
    /// threads). Off, the log says only that a line arrived and how long it was.
    var logTranscriptText: Bool {
        get { logTranscript.load(ordering: .relaxed) }
        set { logTranscript.store(newValue, ordering: .relaxed) }
    }
    private let logTranscript = Atomic<Bool>(false)

    /// The log line for a recognised or suppressed utterance: the text itself
    /// only when the preference allows, else its length.
    static func utteranceLogLine(_ event: String, _ text: String, includeText: Bool) -> String {
        includeText ? "[advisor] \(event): \"\(text)\"" : "[advisor] \(event): \(text.count) chars"
    }

    convenience init(store: TranscriptStore, locale: String) throws {
        try self.init(
            store: store,
            micEngine: AppleSpeechEngine(name: "mic", locale: locale),
            sysEngine: AppleSpeechEngine(name: "sys", locale: locale),
            capture: AudioCapture(),
            systemCapture: SystemAudioCapture(),
            requestMicPermission: { await AudioCapture.requestPermission() },
            requestSystemAccess: { SystemAudioCapture.requestAccessIfNeeded() })
    }

    init(
        store: TranscriptStore,
        micEngine: any SpeechEngineProtocol,
        sysEngine: any SpeechEngineProtocol,
        capture: any MicrophoneCaptureProtocol = AudioCapture(),
        systemCapture: any SystemAudioCaptureProtocol = SystemAudioCapture(),
        requestMicPermission: @escaping @Sendable () async -> Bool = {
            await AudioCapture.requestPermission()
        },
        requestSystemAccess: @escaping @MainActor @Sendable () -> Bool = {
            SystemAudioCapture.requestAccessIfNeeded()
        }
    ) throws {
        self.store = store
        appleMic = micEngine
        appleSys = sysEngine
        self.capture = capture
        self.systemCapture = systemCapture
        self.requestMicPermission = requestMicPermission
        self.requestSystemAccess = requestSystemAccess

        // The engine tags each result with the session token it was started with,
        // so a result from a superseded session is dropped at the store write.
        appleMic.onFinal = { [weak self] text, gen in self?.acceptAsync(text, from: .me, gen: gen) }
        appleSys.onFinal = { [weak self] text, gen in self?.acceptAsync(text, from: .them, gen: gen) }
        appleMic.onVolatile = { [weak self] text, gen in self?.setVolatile(text, for: .me, gen: gen) }
        appleSys.onVolatile = { [weak self] text, gen in self?.setVolatile(text, for: .them, gen: gen) }
        appleMic.onUnexpectedEnd = { [weak self] error, gen, runToken in
            self?.recoverFromSpeechEnd(
                engineName: "mic", error: error, gen: gen, runToken: runToken)
        }
        appleSys.onUnexpectedEnd = { [weak self] error, gen, runToken in
            self?.recoverFromSpeechEnd(
                engineName: "sys", error: error, gen: gen, runToken: runToken)
        }

        capture.onSamples = { [weak self] samples in
            guard let self,
                self.samplesEnabled.load(ordering: .relaxed),
                !self.micMuted.load(ordering: .relaxed)
            else { return }
            self.appleMic.append(samples)
        }
        systemCapture.onSamples = { [weak self] samples in
            guard let self, self.samplesEnabled.load(ordering: .relaxed) else { return }
            self.appleSys.append(samples)
        }
        systemCapture.onStopped = { [weak self] error in
            guard let self else { return }
            self.systemActive.store(false, ordering: .relaxed)
            Task { @MainActor in
                guard self.desiredRunning,
                    self.samplesEnabled.load(ordering: .relaxed)
                else { return }
                if let error {
                    self.store.status = SystemAudioCapture.startFailureNote(for: error)
                } else {
                    self.store.status = "system audio stopped: ok"
                }
            }
        }
    }

    private func recoverFromSpeechEnd(engineName: String, error: Error, gen: Int, runToken: Int) {
        Task { @MainActor in
            guard self.desiredRunning,
                gen == self.store.sessionGeneration,
                runToken == self.speechRunToken
            else { return }

            // A result stream can fail while its start is still suspended. Do
            // not let the remaining setup publish a live session with dead STT.
            // The serial stop cleans any partially-created engine state.
            guard self.store.listening else {
                appLog.write(
                    "[advisor] apple-stt(\(engineName)) ended during start; stopping: \(error)")
                _ = self.requestStop(status: "Apple STT failed during start: \(error)")
                return
            }

            if self.recoveryInFlight {
                appLog.write(
                    "[advisor] apple-stt(\(engineName)) ended during STT recovery; stopping: \(error)")
                _ = self.requestStop(
                    status: "Apple STT failed after restart: \(error)")
                return
            }

            self.recoveryInFlight = true
            self.lifecycleEpoch += 1
            let epoch = self.lifecycleEpoch
            let restartRunToken = self.nextSpeechRunToken()
            let restartSystem = self.systemActive.load(ordering: .relaxed)
            self.samplesEnabled.store(false, ordering: .relaxed)
            self.stopMicrophoneSource()
            self.store.status = "Apple STT stopped; restarting…"
            appLog.write("[advisor] apple-stt(\(engineName)) ended unexpectedly; restarting STT: \(error)")

            _ = self.enqueueLifecycle {
                await self.performRecovery(
                    epoch: epoch,
                    sessionGeneration: gen,
                    runToken: restartRunToken,
                    restartSystem: restartSystem)
            }
        }
    }

    @MainActor
    private func nextSpeechRunToken() -> Int {
        speechRunToken += 1
        return speechRunToken
    }

    @MainActor
    private func isCurrent(_ epoch: Int) -> Bool {
        desiredRunning && lifecycleEpoch == epoch && !Task.isCancelled
    }

    @MainActor
    private func enqueueLifecycle(
        _ operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let previous = lifecycleTail
        let task = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
        lifecycleTail = task
        return task
    }

    @MainActor
    private func performRecovery(
        epoch: Int,
        sessionGeneration: Int,
        runToken: Int,
        restartSystem: Bool
    ) async {
        // Finish draining both sources before touching either sink. Once sink
        // teardown begins, complete it even if stop invalidates this recovery;
        // the queued stop then sees no live sinks and does not repeat teardown.
        await stopSystem()
        await stopSinksIfNeeded()
        guard isCurrent(epoch) else { return }

        sinksMayBeActive = true
        do {
            try await appleMic.start(
                sessionToken: sessionGeneration, runToken: runToken)
            guard isCurrent(epoch) else { return }
            try await appleSys.start(
                sessionToken: sessionGeneration, runToken: runToken)
            guard isCurrent(epoch) else { return }

            var notes: [String] = []
            if restartSystem {
                do {
                    try await systemCapture.start()
                    systemActive.store(true, ordering: .relaxed)
                } catch {
                    notes.append(SystemAudioCapture.startFailureNote(for: error))
                }
                guard isCurrent(epoch) else { return }
            }

            samplesEnabled.store(true, ordering: .relaxed)
            do {
                try capture.start(device: currentDevice, echoCancellation: false)
                micCaptureActive = true
            } catch {
                samplesEnabled.store(false, ordering: .relaxed)
                _ = requestStop(
                    status: "Apple STT failed after restart: \(error)")
                return
            }
            guard isCurrent(epoch) else { return }

            recoveryInFlight = false
            let status = ([listeningStatus] + notes).joined(separator: " | ")
            store.status = "\(status) | Apple STT restarted"
        } catch {
            guard isCurrent(epoch) else { return }
            _ = requestStop(
                status: "Apple STT failed after restart: \(error)")
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
        pendingAcceptance.enter()
        let spokenEnd = Date()
        appLog.write(Self.utteranceLogLine("apple(\(source))", text, includeText: logTranscriptText))
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
        let text = Self.cleanedTranscript(text)
        guard !text.isEmpty, !Self.isJunk(text) else {
            pendingAcceptance.leave()
            return
        }

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
                appLog.write(Self.utteranceLogLine("echo suppressed", text, includeText: logTranscriptText))
                pendingAcceptance.leave()
                return
            }
        }

        let latency = Int(Date().timeIntervalSince(spokenEnd) * 1000)
        let distinctiveSet = Set(Self.distinctive(tokens))
        Task { @MainActor in
            defer { self.pendingAcceptance.leave() }
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

    static func tokens(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Remove speech fillers and collapse immediately repeated words while
    /// retaining the punctuation between the words that remain. Apple sometimes
    /// returns long runs such as "I, I, I, uh" in a single final result; cleaning
    /// here keeps the live feed, saved note and sidecar input consistent.
    static func cleanedTranscript(_ text: String) -> String {
        let regex = try! NSRegularExpression(
            pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*"#)
        let source = text as NSString
        let matches = regex.matches(
            in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return "" }

        let fillers: Set<String> = ["um", "uh", "er", "erm"]
        var output = ""
        var previousMatchEnd = 0
        var lastKeptEnd = 0
        var lastKeptWord: String?
        var keptAny = false
        var lastMatchWasKept = false

        for match in matches {
            let word = source.substring(with: match.range)
            let normalised = word.lowercased()
            let shouldDrop = fillers.contains(normalised) || normalised == lastKeptWord

            if shouldDrop {
                previousMatchEnd = NSMaxRange(match.range)
                lastMatchWasKept = false
                continue
            }

            if keptAny {
                let separator = NSRange(
                    location: previousMatchEnd,
                    length: match.range.location - previousMatchEnd)
                output += source.substring(with: separator)
            } else if let first = matches.first, first.range.location > 0 {
                output += source.substring(
                    with: NSRange(location: 0, length: first.range.location))
            }
            output += word
            keptAny = true
            lastKeptWord = normalised
            previousMatchEnd = NSMaxRange(match.range)
            lastKeptEnd = previousMatchEnd
            lastMatchWasKept = true
        }

        guard keptAny else { return "" }
        if lastMatchWasKept, previousMatchEnd < source.length {
            output += source.substring(from: previousMatchEnd)
        } else if lastKeptEnd < source.length {
            let tail = source.substring(from: lastKeptEnd)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = tail.range(
                of: #"[.!?…]+[\"”’')\]]*$"#, options: .regularExpression)
            {
                output += tail[range]
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Non-speech artefacts: "[BLANK_AUDIO]", "*Bell rings*", "(claps)", lone punctuation.
    static func isJunk(_ text: String) -> Bool {
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
    static func distinctive(_ tokens: [String]) -> [String] {
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
        let now = Date()
        recentThem.removeAll { now.timeIntervalSince($0.time) > 15 }
        // Short replies carry meaning even without a long word. Only an exact
        // recent system utterance provides enough evidence to call them echoes.
        if mine.isEmpty { return recentThem.contains { $0.tokens == tokens } }
        return recentThem.contains { entry in
            Self.pairMatch(mine, Set(Self.distinctive(entry.tokens)))
        }
    }

    /// Register a start synchronously so a following close/stop can invalidate
    /// it even before its first suspension resumes.
    @MainActor
    @discardableResult
    func start(device: InputDevice?, captureSystem: Bool) -> Task<Void, Never> {
        desiredRunning = true
        recoveryInFlight = false
        lifecycleEpoch += 1
        let epoch = lifecycleEpoch
        let sessionGeneration = store.sessionGeneration
        let runToken = nextSpeechRunToken()
        currentDevice = device

        samplesEnabled.store(false, ordering: .relaxed)
        stopMicrophoneSource()
        store.listening = false
        store.status = "starting Apple speech engine…"

        return enqueueLifecycle {
            await self.performStart(
                epoch: epoch,
                sessionGeneration: sessionGeneration,
                runToken: runToken,
                device: device,
                captureSystem: captureSystem)
        }
    }

    @MainActor
    private func performStart(
        epoch: Int,
        sessionGeneration: Int,
        runToken: Int,
        device: InputDevice?,
        captureSystem: Bool
    ) async {
        // A direct duplicate start is treated like a restart. Normal resume has
        // an earlier queued stop, so these are no-ops there.
        await stopSystem()
        await stopSinksIfNeeded()
        guard isCurrent(epoch) else { return }

        guard await requestMicPermission() else {
            guard isCurrent(epoch) else { return }
            desiredRunning = false
            lifecycleEpoch += 1
            store.status = "microphone permission denied"
            return
        }
        guard isCurrent(epoch) else { return }

        sinksMayBeActive = true
        do {
            try await appleMic.start(
                sessionToken: sessionGeneration, runToken: runToken)
            guard isCurrent(epoch) else { return }
            try await appleSys.start(
                sessionToken: sessionGeneration, runToken: runToken)
            guard isCurrent(epoch) else { return }
        } catch {
            guard isCurrent(epoch) else { return }
            _ = requestStop(status: "Apple STT failed: \(error)")
            return
        }

        var notes: [String] = []
        systemActive.store(false, ordering: .relaxed)
        if captureSystem {
            if requestSystemAccess() {
                do {
                    try await systemCapture.start()
                    systemActive.store(true, ordering: .relaxed)
                } catch {
                    notes.append(SystemAudioCapture.startFailureNote(for: error))
                }
                guard isCurrent(epoch) else { return }
            } else {
                notes.append(SystemAudioCapture.permissionRequiredNote)
            }
        }

        // Both sinks are ready before either source can feed them. AEC remains
        // disabled: it fails or mutes the mic on supported multichannel setups.
        samplesEnabled.store(true, ordering: .relaxed)
        do {
            try capture.start(device: device, echoCancellation: false)
            micCaptureActive = true
        } catch {
            samplesEnabled.store(false, ordering: .relaxed)
            _ = requestStop(status: "error: \(error)")
            return
        }
        guard isCurrent(epoch) else { return }

        let detail = [
            "listening — \(device?.label ?? "default input")",
            systemActive.load(ordering: .relaxed) ? "+ system audio" : nil,
        ]
        .compactMap { $0 }.joined(separator: " ")
        listeningStatus = detail
        store.listening = true
        store.status = ([detail] + notes).joined(separator: " | ")
    }

    @MainActor
    @discardableResult
    func stop() -> Task<Void, Never> {
        requestStop(status: "idle")
    }

    @MainActor
    private func requestStop(status: String) -> Task<Void, Never> {
        let hasLifecycleWork = desiredRunning
            || sinksMayBeActive
            || micCaptureActive
            || systemActive.load(ordering: .relaxed)
            || recoveryInFlight
        if !hasLifecycleWork, !stopQueued {
            store.listening = false
            store.micMuted = false
            store.volatile = [:]
            store.status = status
            return enqueueLifecycle { await self.drainTranscripts() }
        }

        desiredRunning = false
        recoveryInFlight = false
        lifecycleEpoch += 1
        _ = nextSpeechRunToken()
        samplesEnabled.store(false, ordering: .relaxed)
        micMuted.store(false, ordering: .relaxed)
        stopMicrophoneSource()
        store.listening = false
        store.micMuted = false
        store.volatile = [:]
        pendingStopStatus = status
        store.status = status == "idle" ? "stopping…" : status

        if stopQueued, let lifecycleTail { return lifecycleTail }
        stopQueued = true
        return enqueueLifecycle {
            await self.performStop()
        }
    }

    @MainActor
    private func performStop() async {
        // Mic source was synchronously drained by requestStop. Drain the async
        // system source before touching either plain-state speech sink.
        await stopSystem()
        await stopSinksIfNeeded()
        await drainTranscripts()
        stopQueued = false
        guard !desiredRunning else { return }
        store.status = pendingStopStatus
    }

    @MainActor
    private func stopMicrophoneSource() {
        guard micCaptureActive else { return }
        micCaptureActive = false
        capture.stop()
    }

    @MainActor
    private func stopSinksIfNeeded() async {
        guard sinksMayBeActive else { return }
        await appleMic.stop()
        await appleSys.stop()
        sinksMayBeActive = false
    }

    /// Call after both result streams finish: no new finals can enter the group.
    /// notify suspends without blocking the main actor needed by pending writes.
    func drainTranscripts() async {
        await withCheckedContinuation { continuation in
            pendingAcceptance.notify(queue: sttQueue) { continuation.resume() }
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

    @MainActor
    private func stopSystem() async {
        guard systemActive.load(ordering: .relaxed) else { return }
        systemActive.store(false, ordering: .relaxed)
        await systemCapture.stop()
    }
}
