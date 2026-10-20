import Foundation

struct Card: Identifiable, Equatable {
    let id: String
    let created: Date
    var kind: String
    var title: String
    var body: String
    var state: String // pending | streaming | done | failed | cancelled
    /// Utterance id this card answers (from the protocol `trigger`). Lets the
    /// session writer footnote-link the card to its transcript line. Nil for
    /// Ask-box/query cards with no anchor.
    var triggerId: String?
    /// The transcript phrase that spawned the card, shown in the footer
    /// (`↳ "…"`). Derived from `triggerId` → utterance text on ingest.
    var triggerQuote: String?
    /// A footer line with no live equivalent, kept from a saved note — a
    /// follow-up's `Asked …` stamp. Nil for live cards.
    var footnote: String?
    /// Whether the card is expanded. Long cards collapse to their header so they
    /// don't bury the live transcript; fact-checks default collapsed.
    var isExpanded: Bool = true
    /// True while a follow-up the user typed into this card is being answered.
    /// App-only (never from the protocol): suppresses the cancel button and the
    /// reply field so a card can't take a second follow-up mid-answer.
    var replying: Bool = false
    /// The card's last completed answer. A follow-up or re-summarise replaces
    /// `body` while it runs; this keeps the answer that was there, so the note
    /// never loses it and a cancelled one (or a failed re-summarise) can put it
    /// back. Nil until the card first completes.
    var settledBody: String?
    /// What the agent is doing while the card researches ("Searching the web for
    /// “Cedar”"), from the sidecar's `activity`. Each update replaces it; nil once
    /// the research ends. Shown on the card only, never saved.
    var activity: String?

    /// Maps the streaming `state` onto the spec's research lifecycle: a card is
    /// "researching" (spinner) until its first terminal state.
    var isResearching: Bool { state == "pending" || state == "streaming" }

    /// The card as the saved note holds it: a finished card (done or failed) as
    /// it stands; one mid-follow-up or mid-re-run as its last completed answer;
    /// one still on its first run, not at all.
    var persisted: Card? {
        if state == "done" || state == "failed" { return self }
        guard let settledBody else { return nil }
        var card = self
        card.body = settledBody
        card.state = "done"
        return card
    }

    /// Signature of what the session note holds of `cards` — each one as
    /// `persisted` — so the note is rewritten when that changes, and not on every
    /// streaming frame or an expand/collapse. Adding or removing a saved card
    /// changes it too.
    static func writerKey(_ cards: [Card]) -> [String] {
        cards.compactMap(\.persisted).map {
            "\($0.id)|\($0.state)|\($0.title)|\($0.body)"
        }
    }

    /// Apply a sidecar `card_update`'s body, state and activity.
    mutating func apply(body newBody: String?, state: String?, activity newActivity: String? = nil) {
        if let newBody { body = newBody }
        // Set after the state below, so a card that has stopped researching drops it.
        defer { activity = isResearching ? newActivity : nil }
        guard let state else { return }
        // A follow-up answer reaching a terminal state re-enables the reply
        // field for another turn.
        if state == "done" || state == "failed" || state == "cancelled" {
            replying = false
        }
        switch (state, settledBody) {
        case ("done", _):
            self.state = state
            settledBody = self.body
        case ("cancelled", let settled?),
             // A sidecar crash fails in-flight cards with no body (issue #49);
             // a follow-up it cut off has no answer to keep, so the last stands.
             ("failed", let settled?) where newBody == nil && kind != "summary":
            // An abandoned follow-up or re-summarise: the last answer stands.
            self.body = settled
            self.state = "done"
        case ("failed", let settled?) where kind == "summary":
            // A failed reply already carries its thread; a failed re-summarise
            // carries only the error, so keep the summary and say so.
            body = "\(settled)\n\n*Couldn't update the summary\(Self.failureReason(newBody))*"
            self.state = state
        default:
            self.state = state
        }
    }

    /// ": <reason>" from the sidecar's failure text ("failed: timed out",
    /// "error: …"), or "." when there is none — a sidecar crash sends no body.
    /// Plain text on one line: it sits inside an italic span.
    private static func failureReason(_ text: String?) -> String {
        guard let text else { return "." }
        let firstLine = (text.hasPrefix("failed: ") ? text.dropFirst(8) : Substring(text))
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let plain = firstLine.filter { !"*_`[]".contains($0) }.trimmingCharacters(in: .whitespaces)
        return plain.isEmpty ? "." : ": \(plain)"
    }

    /// Cancelled from the app (Stop and Close), before the sidecar confirms.
    mutating func cancel() {
        apply(body: nil, state: "cancelled")
    }
}

/// Main-actor registry for saved-document requests. Removing terminal handlers
/// before invoking them prevents late frames or re-entrant callbacks from
/// retaining a completed Sessions view.
@MainActor
final class DocumentRequestHandlers {
    typealias Handler = (String, String) -> Void

    private var handlers: [String: Handler] = [:]

    var count: Int { handlers.count }

    func register(_ id: String, handler: @escaping Handler) {
        handlers[id] = handler
    }

    func remove(_ id: String) {
        handlers[id] = nil
    }

    func receive(id: String, body: String, state: String) {
        guard let handler = handlers[id] else { return }
        if Self.isTerminal(state) { handlers[id] = nil }
        handler(body, state)
    }

    func failAll(reason: String) {
        let pending = Array(handlers.values)
        handlers.removeAll()
        for handler in pending { handler(reason, "failed") }
    }

    private static func isTerminal(_ state: String) -> Bool {
        state == "done" || state == "failed" || state == "cancelled"
    }
}

/// Spawns and supervises the Node sidecar; NDJSON over stdio.
@MainActor
final class SidecarManager {
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var buffer = Data()
    private let store: TranscriptStore
    private let sidecarDir = AppResources.sidecarDir
    private let loadConfig: () -> AdvisorConfig
    private let readKey: (Keychain.Key) -> String?
    private let launchProcess: (Process) throws -> Void
    private let baseEnvironment: [String: String]
    private var spawnedAuth: [String: String]?
    private var generation = 0
    /// stdin writes run here, off the main thread: a hung sidecar that stops
    /// draining its stdin must not block the UI on a full-pipe `write`.
    private let writeQueue = DispatchQueue(label: "advisor.sidecar.write")

    // Crash recovery: a crashed sidecar leaves listening alive but mute (no
    // cards, no query). Restart with backoff and replay the session context the
    // running conversation depends on. (In-flight utterances at crash time are
    // not replayed — the classifier session is gone; new utterances flow into a
    // fresh session via the replayed session_start.) A deliberate stop() needs
    // no flag: it bumps the generation, which every crash, spawn-failure and
    // backoff callback checks first.
    private var restartAttempts = 0
    /// How long a sidecar gets to leave on its own after its stdin closes
    /// before it is terminated (see discardProcess).
    private let exitGrace: TimeInterval
    private let maxRestarts = 5
    /// A sidecar that ran this long before crashing is treated as healthy, so
    /// the backoff budget resets — only a tight crash loop exhausts maxRestarts.
    private let healthyRunSeconds: TimeInterval
    /// The backoff before restart attempt n (1-based): 1, 2, 4, 8, 8 s.
    private let restartDelay: (Int) -> TimeInterval
    nonisolated static func defaultRestartDelay(_ attempt: Int) -> TimeInterval {
        min(8.0, pow(2.0, Double(attempt - 1)))
    }
    private var lastSpawn: Date?
    private var lastSessionId: String?
    private var lastSessionContext = ""
    private var lastLanes: Int?
    private var lastAuto: Bool?

    init(
        store: TranscriptStore,
        loadConfig: @escaping () -> AdvisorConfig = { AdvisorConfig.load() },
        readKey: @escaping (Keychain.Key) -> String? = { Keychain.read($0) },
        launchProcess: @escaping (Process) throws -> Void = { try $0.run() },
        environment: [String: String] = ProcessInfo.processInfo.environment,
        exitGrace: TimeInterval = 2,
        healthyRunSeconds: TimeInterval = 60,
        restartDelay: @escaping (Int) -> TimeInterval = SidecarManager.defaultRestartDelay
    ) {
        self.store = store
        self.loadConfig = loadConfig
        self.readKey = readKey
        self.launchProcess = launchProcess
        self.exitGrace = exitGrace
        self.healthyRunSeconds = healthyRunSeconds
        self.restartDelay = restartDelay
        baseEnvironment = environment
        // Writing to a sidecar that has died closes its read end → SIGPIPE, which
        // would kill the app. Ignore it; the write throws EPIPE instead, handled
        // below. (Process-global, set once.)
        signal(SIGPIPE, SIG_IGN)
    }

    func start() {
        guard process == nil else { return }
        restartAttempts = 0
        spawn()
    }

    /// Environment additions carrying the active provider's API key, read fresh
    /// from config + Keychain at each spawn. Empty for subscription auth (the
    /// default) or when no key is stored, leaving the SDKs on their CLI login.
    private func apiKeyEnv() -> [String: String] {
        let config = loadConfig()
        guard config.authMode == "apiKey" else { return [:] }
        switch config.provider {
        case "codex":
            if let key = readKey(.openai) { return ["OPENAI_API_KEY": key] }
        default:
            if let key = readKey(.anthropic) { return ["ANTHROPIC_API_KEY": key] }
        }
        return [:]
    }

    private func spawn(auth: [String: String]? = nil) {
        generation += 1
        let generation = generation
        let auth = auth ?? apiKeyEnv()
        // Drop any partial NDJSON frame left by a crashed sidecar: otherwise the
        // stale bytes would prefix (and corrupt) the first frame from the new one.
        buffer = Data()
        let p = Process()
        // Base env + any provider API key (empty unless "API key" auth is selected
        // and a key is stored). The key reaches the SDKs purely through the
        // environment — the sidecar code never sees config secrets.
        var env = baseEnvironment
        env["ANTHROPIC_API_KEY"] = nil
        env["OPENAI_API_KEY"] = nil
        env["ADVISOR_CHILD_API_KEY"] = nil
        env["ADVISOR_CHILD_API_KEY_NAME"] = nil
        for (key, value) in auth { env[key] = value }
        if let node = AppResources.bundledNode {
            // Packaged app: run the bundled Node directly; no system Node needed.
            // Child processes the Agent SDK spawns reuse this via process.execPath.
            p.executableURL = URL(fileURLWithPath: node)
            p.arguments = ["dist/main.js"]
            let nodeDir = URL(fileURLWithPath: node).deletingLastPathComponent().path
            env["PATH"] = nodeDir + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        } else {
            // The login profile supplies Node's PATH but may also export API
            // keys. Restore the selected authentication after it runs, without
            // putting a secret in command arguments or the NDJSON protocol.
            if let (name, key) = auth.first {
                env["ADVISOR_CHILD_API_KEY_NAME"] = name
                env["ADVISOR_CHILD_API_KEY"] = key
            }
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", """
                unset ANTHROPIC_API_KEY OPENAI_API_KEY
                if [[ -n "$ADVISOR_CHILD_API_KEY_NAME" ]]; then
                    export "$ADVISOR_CHILD_API_KEY_NAME=$ADVISOR_CHILD_API_KEY"
                fi
                unset ADVISOR_CHILD_API_KEY ADVISOR_CHILD_API_KEY_NAME
                exec node dist/main.js
                """]
        }
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: sidecarDir)
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.consume(data)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { appLog.appendSidecar(data) }
        }
        p.terminationHandler = { [weak self] proc in
            // Detach the read handlers: once the process is gone the read ends
            // signal readable-with-0-bytes in a tight loop until dealloc (issue #63).
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            appLog.flushSidecar()   // emit any buffered partial stderr line
            Task { @MainActor in
                self?.handleTermination(proc.terminationStatus, generation: generation)
            }
        }
        do {
            try launchProcess(p)
            process = p
            stdinHandle = inPipe.fileHandleForWriting
            spawnedAuth = auth
            lastSpawn = Date()
        } catch {
            // The process never started, so its terminationHandler will never fire.
            // Detach the handlers and schedule a retry here, or a spawn failure
            // during restart() strands the sidecar with no recovery (issue #63).
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor [weak self] in
                self?.handleSpawnFailure(error, generation: generation)
            }
        }
    }

    @MainActor
    private func handleTermination(_ code: Int32, generation: Int) {
        // A deliberate stop() never reaches here: discardProcess bumps the
        // generation first, so this is always a genuine crash.
        guard self.generation == generation else { return }
        stdinHandle = nil
        process = nil
        spawnedAuth = nil
        documentHandlers.failAll(reason: "sidecar crashed (\(code))")
        // Genuine crash: the restarted sidecar has no memory of prior card ids, so
        // any still-researching card can never receive its terminal card_update and
        // would spin forever (issue #49). Fail them now — on every crash path
        // (restart and exhausted-attempts alike), before the restart backoff below.
        failResearchingCards()
        // A crash after a healthy run is a fresh failure, not part of a loop.
        if let lastSpawn, Date().timeIntervalSince(lastSpawn) > healthyRunSeconds {
            restartAttempts = 0
        }
        scheduleRestart(reason: "sidecar crashed (\(code))")
    }

    /// Fail every card still researching: the sidecar answering them has gone.
    private func failResearchingCards() {
        for idx in store.cards.indices where store.cards[idx].isResearching {
            store.cards[idx].apply(body: nil, state: "failed")
        }
    }

    /// A spawn that threw before the process ever ran (issue #63): no
    /// terminationHandler will fire, so drive recovery from here on the same
    /// backoff budget rather than leaving the sidecar stranded.
    @MainActor
    private func handleSpawnFailure(_ error: Error, generation: Int) {
        guard self.generation == generation else { return }
        stdinHandle = nil
        process = nil
        spawnedAuth = nil
        documentHandlers.failAll(reason: "sidecar failed to start: \(error)")
        scheduleRestart(reason: "sidecar failed to start: \(error)")
    }

    /// Schedule a backoff restart under the shared attempt budget, or report
    /// exhaustion. `reason` is the failure prefix for the status line.
    @MainActor
    private func scheduleRestart(reason: String) {
        guard restartAttempts < maxRestarts else {
            store.status = "\(reason) — restart attempts exhausted; stop and start listening again"
            return
        }
        restartAttempts += 1
        let attempt = restartAttempts
        let delay = restartDelay(attempt)
        store.status = "\(reason); restarting (\(attempt)/\(maxRestarts))…"
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard self?.generation == generation else { return }
            self?.restart()
        }
    }

    @MainActor
    private func restart() {
        spawn()
        guard process != nil else { return } // spawn failed; status already set
        // Replay the session context the running conversation depends on.
        if let lastLanes { sendLanes(lastLanes) }
        if let lastAuto { sendAuto(lastAuto) }
        if let lastSessionId { sendSessionStartFrame(lastSessionId, context: lastSessionContext) }
    }

    @MainActor
    func stop() {
        lastSessionId = nil
        lastSessionContext = ""
        discardProcess()
        documentHandlers.failAll(reason: "sidecar stopped")
    }

    /// `stop()` for the way out (⌘Q's `finishQuit`): the app exits synchronously
    /// straight after, so the delayed backstop in `discardProcess` would never
    /// fire. Close stdin, then wait up to `grace` for the sidecar to leave on its
    /// own — the clean path, which takes its CLI children with it — and
    /// terminate it only if it is still there. Blocks the main thread for at
    /// most `grace`, whatever state the sidecar is in: the stdin close is queued
    /// behind any in-flight write, and a write blocked on a wedged sidecar's full
    /// pipe must not hold up the exit, so the wait on it is bounded too.
    @MainActor
    func stopForExit(waitingUpTo grace: TimeInterval? = nil) {
        let grace = grace ?? exitGrace
        let leaving = process
        stop()
        guard let leaving, leaving.isRunning else { return }
        let deadline = Date().addingTimeInterval(grace)
        let closed = DispatchSemaphore(value: 0)
        writeQueue.async { closed.signal() } // runs after the close discardProcess queued
        if closed.wait(timeout: .now() + grace) == .success {
            while leaving.isRunning && Date() < deadline { usleep(10_000) }
        }
        if leaving.isRunning { leaving.terminate() }
    }

    private func discardProcess() {
        // Invalidate callbacks before requesting exit. Old termination/output
        // and backoff callbacks must never clear or restart the replacement.
        generation += 1
        // Close on writeQueue so it serialises with in-flight async writes (a
        // close racing a write mid-syscall is an fd-reuse hazard). The sidecar
        // exits at once on stdin close — through Node's exit handlers, where the
        // Agent SDK kills the CLI processes it spawned. A SIGTERM skips those and
        // orphans them, so it is only the backstop for a sidecar that fails to
        // leave (code review 2026-10-17; it used to be sent in the same instant,
        // which made the sidecar's own exit path unreachable).
        if let handle = stdinHandle { writeQueue.async { try? handle.close() } }
        stdinHandle = nil
        if let process, process.isRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + exitGrace) {
                if process.isRunning { process.terminate() }
            }
        }
        process = nil
        spawnedAuth = nil
    }

    // MARK: outbound

    /// Start a session on the sidecar, which clears its transcript, then send
    /// `notes` — the ones typed before Listen (issue #104) — so the agents read
    /// them.
    func sendSessionStart(_ id: String, context: String = "", notes: [EditorialNote] = []) {
        lastSessionId = id
        lastSessionContext = context // replayed verbatim if the sidecar restarts
        let auth = apiKeyEnv()
        if process == nil || spawnedAuth != auth {
            // A replaced sidecar can't finish the cards it was answering — a
            // question asked before Listen keeps its card (issue #104).
            if process != nil { failResearchingCards() }
            discardProcess()
            documentHandlers.failAll(reason: "authentication changed — request cancelled")
            restartAttempts = 0
            spawn(auth: auth)
            guard process != nil else { return } // recovery replays session_start
            if let lastLanes { sendLanes(lastLanes) }
            if let lastAuto { sendAuto(lastAuto) }
        }
        sendSessionStartFrame(id, context: context)
        notes.forEach(sendNote)
    }

    private func sendSessionStartFrame(_ id: String, context: String) {
        var msg: [String: Any] = [
            "type": "session_start", "sessionId": id, "ts": Date().timeIntervalSince1970,
        ]
        if !context.isEmpty { msg["context"] = context }
        send(msg)
    }

    func sendSessionEnd() {
        lastSessionId = nil // nothing to replay after the session ends
        lastSessionContext = ""
        send(["type": "session_end"])
    }

    /// Live edit of the session prompt mid-session. Stored so a sidecar restart
    /// replays the latest text via session_start.
    func sendSessionContext(_ text: String) {
        lastSessionContext = text
        send(["type": "session_context", "text": text])
    }

    func sendUtterance(_ u: Utterance) {
        send([
            "type": "utterance",
            "id": u.id.uuidString,
            "source": u.source.rawValue,
            "text": u.text,
            "ts": u.time.timeIntervalSince1970,
        ])
    }

    /// Forward an editorial note (issue #34) into the sidecar's transcript stream,
    /// where the classifier and every research/query lane read it as labelled user
    /// context. Append-only like utterances — a later delete is display-only.
    func sendNote(_ note: EditorialNote) {
        send([
            "type": "note",
            "id": note.id.uuidString,
            "text": note.text,
            "ts": note.time.timeIntervalSince1970,
        ])
    }

    func sendQuery(_ text: String) {
        send(["type": "query", "id": UUID().uuidString, "text": text])
    }

    /// Summarise the live session (issue #30). `transcript` is the whole
    /// conversation so far; `cardId` is the existing summary card on a re-summarise
    /// (so the sidecar updates it in place) or nil the first time. The summary
    /// streams back as a `summary`-kind card / card_update. Returns whether the
    /// message was sent, so the caller can clear its in-flight guard if the
    /// sidecar is down (no card is coming).
    @discardableResult
    func sendSummariseLive(cardId: String?, transcript: String) -> Bool {
        var msg: [String: Any] = ["type": "summarise_live", "transcript": transcript]
        if let cardId { msg["cardId"] = cardId }
        return send(msg)
    }

    /// Pending document-request answer streams, keyed by request id. Registered
    /// by `sendDocumentRequest`, invoked as `document_answer` frames arrive,
    /// dropped on a terminal state. Main-actor confined: the requests and inbound
    /// handling both run on the main actor.
    @MainActor private lazy var documentHandlers = DocumentRequestHandlers()

    /// Ask a question about a saved transcript (the history browser). `onUpdate`
    /// is called with the streamed answer body and state
    /// ("pending"|"streaming"|"done"|"failed"|"cancelled"); it fires no more
    /// after the first terminal state. Returns the request id, or nil if the
    /// sidecar is down (the message was dropped, so no answer is coming).
    @MainActor
    @discardableResult
    func askDocument(
        question: String, document: String, onUpdate: @escaping (String, String) -> Void
    ) -> String? {
        sendDocumentRequest(
            ["type": "ask_document", "question": question, "document": document], onUpdate: onUpdate)
    }

    /// Summarise a saved transcript (the history browser, issue #30). Like
    /// `askDocument` but with no question — the sidecar runs the summary prompt
    /// over `transcript` and streams the result back via `document_answer`.
    /// Returns the request id, or nil if the sidecar is down.
    @MainActor
    @discardableResult
    func summariseDocument(
        transcript: String, onUpdate: @escaping (String, String) -> Void
    ) -> String? {
        sendDocumentRequest(["type": "summarise_document", "transcript": transcript], onUpdate: onUpdate)
    }

    /// Right-click research on a passage of a saved transcript (the Sessions
    /// browser): `action` is the card kind ("answer" | "context" | "factcheck"),
    /// `document` the whole note. Streams back like `askDocument`. Returns the
    /// request id (cancel with `sendCancel`), or nil if the sidecar is down.
    @MainActor
    @discardableResult
    func researchDocument(
        action: String, text: String, document: String, onUpdate: @escaping (String, String) -> Void
    ) -> String? {
        sendDocumentRequest(
            ["type": "research_document", "action": action, "text": text, "document": document],
            onUpdate: onUpdate)
    }

    /// A follow-up typed into a card of a saved transcript (the Sessions browser):
    /// `card_reply`'s fields with the whole note as context. Streams back the
    /// answer alone, like `askDocument`. Returns the request id, or nil if the
    /// sidecar is down.
    @MainActor
    @discardableResult
    func replyDocument(
        kind: String, title: String, base: String, replyText: String, document: String,
        onUpdate: @escaping (String, String) -> Void
    ) -> String? {
        sendDocumentRequest(
            [
                "type": "reply_document", "kind": kind, "title": title, "base": base,
                "replyText": replyText, "document": document,
            ],
            onUpdate: onUpdate)
    }

    /// Send a document request (`fields` plus a fresh id) whose answer streams
    /// back as `document_answer` frames to `onUpdate`. Returns the id, or nil —
    /// with nothing registered — if the sidecar is down.
    @MainActor
    private func sendDocumentRequest(
        _ fields: [String: Any], onUpdate: @escaping (String, String) -> Void
    ) -> String? {
        let id = UUID().uuidString
        documentHandlers.register(id, handler: onUpdate)
        var message = fields
        message["id"] = id
        guard send(message) else {
            documentHandlers.remove(id)
            return nil
        }
        return id
    }

    /// Stop a document request and forget its handler, so no frame still on its
    /// way — even a `done` — reaches the caller (a deleted in-flight card).
    @MainActor
    func discardDocumentRequest(_ id: String) {
        documentHandlers.remove(id)
        sendCancel(id)
    }

    /// Manual right-click action on selected transcript text. `action` is the
    /// card kind ("answer" | "context" | "factcheck"); `triggerId` anchors the
    /// resulting card under the utterance the selection came from.
    func sendAction(_ action: String, text: String, triggerId: String) {
        send([
            "type": "query",
            "id": UUID().uuidString,
            "text": text,
            "action": action,
            "triggerId": triggerId,
        ])
    }

    func sendAuto(_ enabled: Bool) {
        lastAuto = enabled
        send(["type": "config", "auto": enabled])
    }

    func sendCancel(_ cardId: String) {
        send(["type": "cancel", "cardId": cardId])
    }

    /// Follow-up typed into an existing card. The sidecar holds no card state, so
    /// we send the card's current body (original answer + any prior turns), the
    /// new question, and a recent transcript slice for resolving referents.
    /// Returns false if the message couldn't be sent (sidecar down) so the caller
    /// can skip the optimistic in-card edit rather than leaving a stuck spinner.
    func sendCardReply(
        cardId: String, kind: String, title: String, base: String, replyText: String,
        transcript: String
    ) -> Bool {
        send([
            "type": "card_reply",
            "cardId": cardId,
            "kind": kind,
            "title": title,
            "base": base,
            "replyText": replyText,
            "transcript": transcript,
        ])
    }

    func sendLanes(_ count: Int) {
        lastLanes = count
        send(["type": "config", "lanes": count])
    }

    /// The "Include transcript text in the log" preference, mid-session. Sent
    /// on every preference edit; the sidecar acts only on a change. Skipped,
    /// not reported as dropped, while no sidecar runs: a new one reads
    /// config.json at launch and at every session_start.
    func sendLogTranscriptText(_ on: Bool) {
        guard stdinHandle != nil else { return }
        send(["type": "config", "logTranscriptText": on])
    }

    /// Returns whether the message was accepted (sidecar up and JSON encodable).
    /// The write itself happens asynchronously on `writeQueue`; a write failure
    /// surfaces on the status line rather than in the return value.
    @discardableResult
    private func send(_ message: [String: Any]) -> Bool {
        guard let stdinHandle else {
            setStatus("sidecar not running — message dropped")
            return false
        }
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return false }
        data.append(0x0A)
        let generation = generation
        writeQueue.async { [weak self] in
            do {
                try stdinHandle.write(contentsOf: data)
            } catch {
                Task { @MainActor in
                    guard let self, self.generation == generation else { return }
                    self.store.status = "sidecar write failed: \(error.localizedDescription)"
                }
            }
        }
        return true
    }

    private func setStatus(_ s: String) {
        store.status = s
    }

    // MARK: inbound

    private func consume(_ data: Data) {
        buffer.append(data)
        let (frames, remainder) = Self.ndjsonFrames(buffer)
        buffer = remainder
        for line in frames {
            guard !line.isEmpty,
                let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let type = obj["type"] as? String
            else { continue }
            handle(type: type, obj)
        }
    }

    /// Split accumulated bytes into complete newline-delimited frames and the
    /// trailing partial line. Pure so the NDJSON framing — partial-line assembly
    /// across chunks, multiple frames per chunk — is testable without the live
    /// pipe (issue #65). The caller keeps `remainder` as the next chunk's prefix.
    nonisolated static func ndjsonFrames(_ buffer: Data) -> (frames: [Data], remainder: Data) {
        var frames: [Data] = []
        var rest = buffer
        while let nl = rest.firstIndex(of: 0x0A) {
            frames.append(rest.subdata(in: rest.startIndex..<nl))
            rest.removeSubrange(rest.startIndex...nl)
        }
        return (frames, rest)
    }

    /// Dispatch one decoded frame. Internal, not private, so the contract test
    /// (ProtocolContractTests, issue #97) can feed it the shared example frames.
    @MainActor
    func handle(type: String, _ obj: [String: Any]) {
        switch type {
        case "card":
            guard let id = obj["id"] as? String else { return }
            // Anchor the card to the sentence that triggered it, so it sorts
            // into the feed under that line rather than at research-completion
            // time (10–30s later). Fall back to now for query cards / unknown ids.
            let triggerId = obj["trigger"] as? String
            let anchor = triggerId.flatMap { trigger in
                store.utterances.first { $0.id.uuidString == trigger }
            }
            let kind = obj["kind"] as? String ?? "query"
            let body = obj["body"] as? String ?? ""
            let state = obj["state"] as? String ?? "pending"
            store.cards.append(
                Card(
                    id: id,
                    created: anchor?.time ?? Date(),
                    kind: kind,
                    title: obj["title"] as? String ?? "",
                    body: body,
                    state: state,
                    triggerId: triggerId,
                    triggerQuote: anchor?.text,
                    // Fact-checks default collapsed so they don't bury the
                    // transcript; everything else opens expanded.
                    isExpanded: kind != "factcheck",
                    settledBody: state == "done" ? body : nil))
        case "card_update":
            guard let id = obj["id"] as? String,
                let idx = store.cards.firstIndex(where: { $0.id == id })
            else { return }
            store.cards[idx].apply(
                body: obj["body"] as? String, state: obj["state"] as? String,
                activity: obj["activity"] as? String)
        case "document_answer":
            guard let id = obj["id"] as? String else { return }
            let body = obj["body"] as? String ?? ""
            let state = obj["state"] as? String ?? "streaming"
            documentHandlers.receive(id: id, body: body, state: state)
        case "error":
            store.status = "sidecar: \(obj["message"] as? String ?? "error")"
        default:
            break
        }
    }
}
