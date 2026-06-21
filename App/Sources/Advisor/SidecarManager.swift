import Foundation

/// A fact-check outcome. Drives the verdict badge colour/glyph. Optional on a
/// card because the sidecar does not emit a verdict yet — `factcheck` cards
/// render a neutral pill until it does (see DESIGN.md / handoff Open Questions).
enum Verdict: String, Equatable {
    case verified, needsContext, misleading
}

/// A source link shown in a card footer. The sidecar does not emit these yet
/// (research lanes cite inline in the body markdown); the row stays hidden when
/// `sources` is empty, and lights up if/when the protocol carries them.
struct Citation: Identifiable, Equatable {
    var id: String { url }
    let label: String
    let url: String
}

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
    /// Source links for the footer. Empty until the sidecar emits them.
    var sources: [Citation] = []
    /// Fact-check outcome, when known. Nil for non-factcheck cards and for
    /// factcheck cards before the sidecar emits a verdict.
    var verdict: Verdict?
    /// Whether the card is expanded. Long cards collapse to their header so they
    /// don't bury the live transcript; fact-checks default collapsed.
    var isExpanded: Bool = true
    /// True while a follow-up the user typed into this card is being answered.
    /// App-only (never from the protocol): suppresses the cancel button and the
    /// reply field so a card can't take a second follow-up mid-answer.
    var replying: Bool = false

    /// Maps the streaming `state` onto the spec's research lifecycle: a card is
    /// "researching" (spinner) until its first terminal state.
    var isResearching: Bool { state == "pending" || state == "streaming" }
}

/// Spawns and supervises the Node sidecar; NDJSON over stdio.
final class SidecarManager {
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var buffer = Data()
    private let store: TranscriptStore
    private let sidecarDir = AppResources.sidecarDir
    /// stdin writes run here, off the main thread: a hung sidecar that stops
    /// draining its stdin must not block the UI on a full-pipe `write`.
    private let writeQueue = DispatchQueue(label: "advisor.sidecar.write")

    // Crash recovery: a crashed sidecar leaves listening alive but mute (no
    // cards, no query). Restart with backoff and replay the session context the
    // running conversation depends on. (In-flight utterances at crash time are
    // not replayed — the classifier session is gone; new utterances flow into a
    // fresh session via the replayed session_start.)
    private var stopping = false
    private var restartAttempts = 0
    private let maxRestarts = 5
    /// A sidecar that ran this long before crashing is treated as healthy, so
    /// the backoff budget resets — only a tight crash loop exhausts maxRestarts.
    private let healthyRunSeconds: TimeInterval = 60
    private var lastSpawn: Date?
    private var lastSessionId: String?
    private var lastSessionContext = ""
    private var lastLanes: Int?
    private var lastAuto: Bool?

    init(store: TranscriptStore) {
        self.store = store
        // Writing to a sidecar that has died closes its read end → SIGPIPE, which
        // would kill the app. Ignore it; the write throws EPIPE instead, handled
        // below. (Process-global, set once.)
        signal(SIGPIPE, SIG_IGN)
    }

    func start() {
        restartAttempts = 0
        stopping = false
        spawn()
    }

    /// Environment additions carrying the active provider's API key, read fresh
    /// from config + Keychain at each spawn. Empty for subscription auth (the
    /// default) or when no key is stored, leaving the SDKs on their CLI login.
    private static func apiKeyEnv() -> [String: String] {
        let config = AdvisorConfig.load()
        guard config.authMode == "apiKey" else { return [:] }
        switch config.provider {
        case "codex":
            if let key = Keychain.read(.openai) { return ["OPENAI_API_KEY": key] }
        default:
            if let key = Keychain.read(.anthropic) { return ["ANTHROPIC_API_KEY": key] }
        }
        return [:]
    }

    private func spawn() {
        // Drop any partial NDJSON frame left by a crashed sidecar: otherwise the
        // stale bytes would prefix (and corrupt) the first frame from the new one.
        buffer = Data()
        let p = Process()
        // Base env + any provider API key (empty unless "API key" auth is selected
        // and a key is stored). The key reaches the SDKs purely through the
        // environment — the sidecar code never sees config secrets.
        var env = ProcessInfo.processInfo.environment
        for (key, value) in Self.apiKeyEnv() { env[key] = value }
        if let node = AppResources.bundledNode {
            // Packaged app: run the bundled Node directly; no system Node needed.
            // Child processes the Agent SDK spawns reuse this via process.execPath.
            p.executableURL = URL(fileURLWithPath: node)
            p.arguments = ["dist/main.js"]
            let nodeDir = URL(fileURLWithPath: node).deletingLastPathComponent().path
            env["PATH"] = nodeDir + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        } else {
            // Dev checkout: resolve `node` from the login shell PATH (zsh -l
            // re-sources the profile, so an explicit env here doesn't lose PATH).
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", "exec node dist/main.js"]
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
            self?.consume(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { appLog.appendSidecar(data) }
        }
        p.terminationHandler = { [weak self] proc in
            appLog.flushSidecar()   // emit any buffered partial stderr line
            Task { @MainActor in self?.handleTermination(proc.terminationStatus) }
        }
        do {
            try p.run()
            process = p
            stdinHandle = inPipe.fileHandleForWriting
            lastSpawn = Date()
        } catch {
            Task { @MainActor in self.store.status = "sidecar failed to start: \(error)" }
        }
    }

    @MainActor
    private func handleTermination(_ code: Int32) {
        stdinHandle = nil
        process = nil
        if stopping { stopping = false; return } // deliberate stop()
        // A crash after a healthy run is a fresh failure, not part of a loop.
        if let lastSpawn, Date().timeIntervalSince(lastSpawn) > healthyRunSeconds {
            restartAttempts = 0
        }
        guard restartAttempts < maxRestarts else {
            store.status =
                "sidecar crashed (\(code)) — restart attempts exhausted; stop and start listening again"
            return
        }
        restartAttempts += 1
        let attempt = restartAttempts
        let delay = min(8.0, pow(2.0, Double(attempt - 1))) // 1, 2, 4, 8, 8 s
        store.status = "sidecar crashed (\(code)); restarting (\(attempt)/\(maxRestarts))…"
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.restart()
        }
    }

    @MainActor
    private func restart() {
        guard !stopping else { return } // user stopped during the backoff window
        spawn()
        guard process != nil else { return } // spawn failed; status already set
        // Replay the session context the running conversation depends on.
        if let lastLanes { sendLanes(lastLanes) }
        if let lastAuto { sendAuto(lastAuto) }
        if let lastSessionId { sendSessionStart(lastSessionId, context: lastSessionContext) }
    }

    func stop() {
        stopping = true
        lastSessionId = nil
        lastSessionContext = ""
        // Close on writeQueue so it serialises with in-flight async writes (a
        // close racing a write mid-syscall is an fd-reuse hazard). sidecar exits
        // on stdin close.
        if let handle = stdinHandle { writeQueue.async { try? handle.close() } }
        stdinHandle = nil
        if let process, process.isRunning { process.terminate() } // backstop: no orphan
        process = nil
    }

    // MARK: outbound

    func sendSessionStart(_ id: String, context: String = "") {
        lastSessionId = id
        lastSessionContext = context // replayed verbatim if the sidecar restarts
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

    func sendQuery(_ text: String) {
        send(["type": "query", "id": UUID().uuidString, "text": text])
    }

    /// Pending document-question answer streams, keyed by request id. Registered
    /// by `askDocument`, invoked as `document_answer` frames arrive, dropped on a
    /// terminal state. Main-actor confined: `askDocument` and inbound handling
    /// both run on the main actor.
    @MainActor private var documentHandlers: [String: (String, String) -> Void] = [:]

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
        let id = UUID().uuidString
        documentHandlers[id] = onUpdate
        let sent = send([
            "type": "ask_document", "id": id, "question": question, "document": document,
        ])
        if !sent {
            documentHandlers[id] = nil
            return nil
        }
        return id
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
        writeQueue.async { [weak self] in
            do {
                try stdinHandle.write(contentsOf: data)
            } catch {
                self?.setStatus("sidecar write failed: \(error.localizedDescription)")
            }
        }
        return true
    }

    /// store is @MainActor; send() may be called off the main thread.
    private func setStatus(_ s: String) {
        Task { @MainActor in self.store.status = s }
    }

    // MARK: inbound

    /// Decodes a protocol `sources` value (array of `{label,url}`) defensively;
    /// any malformed entry is skipped. The sidecar does not emit this yet.
    private static func parseSources(_ raw: Any?) -> [Citation] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { entry in
            guard let url = entry["url"] as? String, !url.isEmpty else { return nil }
            return Citation(label: entry["label"] as? String ?? url, url: url)
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let type = obj["type"] as? String
            else { continue }
            Task { @MainActor in self.handle(type: type, obj) }
        }
    }

    @MainActor
    private func handle(type: String, _ obj: [String: Any]) {
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
            store.cards.append(
                Card(
                    id: id,
                    created: anchor?.time ?? Date(),
                    kind: kind,
                    title: obj["title"] as? String ?? "",
                    body: obj["body"] as? String ?? "",
                    state: obj["state"] as? String ?? "pending",
                    triggerId: triggerId,
                    triggerQuote: anchor?.text,
                    sources: Self.parseSources(obj["sources"]),
                    verdict: (obj["verdict"] as? String).flatMap(Verdict.init(rawValue:)),
                    // Fact-checks default collapsed so they don't bury the
                    // transcript; everything else opens expanded.
                    isExpanded: kind != "factcheck"))
        case "card_update":
            guard let id = obj["id"] as? String,
                let idx = store.cards.firstIndex(where: { $0.id == id })
            else { return }
            if let body = obj["body"] as? String { store.cards[idx].body = body }
            if let sources = obj["sources"] { store.cards[idx].sources = Self.parseSources(sources) }
            if let verdict = (obj["verdict"] as? String).flatMap(Verdict.init(rawValue:)) {
                store.cards[idx].verdict = verdict
            }
            if let state = obj["state"] as? String {
                store.cards[idx].state = state
                // A follow-up answer reaching a terminal state re-enables the
                // reply field for another turn.
                if state == "done" || state == "failed" || state == "cancelled" {
                    store.cards[idx].replying = false
                }
            }
        case "document_answer":
            guard let id = obj["id"] as? String, let handler = documentHandlers[id] else { return }
            let body = obj["body"] as? String ?? ""
            let state = obj["state"] as? String ?? "streaming"
            handler(body, state)
            if state == "done" || state == "failed" || state == "cancelled" {
                documentHandlers[id] = nil
            }
        case "error":
            store.status = "sidecar: \(obj["message"] as? String ?? "error")"
        default:
            break
        }
    }
}
