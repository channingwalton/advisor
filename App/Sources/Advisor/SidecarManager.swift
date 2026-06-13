import Foundation

struct Card: Identifiable, Equatable {
    let id: String
    let created: Date
    var kind: String
    var title: String
    var body: String
    var state: String // pending | streaming | done | failed | cancelled
    /// True while a follow-up the user typed into this card is being answered.
    /// App-only (never from the protocol): suppresses the cancel button and the
    /// reply field so a card can't take a second follow-up mid-answer.
    var replying: Bool = false
}

/// Spawns and supervises the Node sidecar; NDJSON over stdio.
final class SidecarManager {
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var buffer = Data()
    private let store: TranscriptStore
    private let sidecarDir = AppResources.sidecarDir

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
    }

    func start() {
        restartAttempts = 0
        stopping = false
        spawn()
    }

    private func spawn() {
        let p = Process()
        if let node = AppResources.bundledNode {
            // Packaged app: run the bundled Node directly; no system Node needed.
            // Child processes the Agent SDK spawns reuse this via process.execPath.
            p.executableURL = URL(fileURLWithPath: node)
            p.arguments = ["dist/main.js"]
            var env = ProcessInfo.processInfo.environment
            let nodeDir = URL(fileURLWithPath: node).deletingLastPathComponent().path
            env["PATH"] = nodeDir + ":" + (env["PATH"] ?? "/usr/bin:/bin")
            p.environment = env
        } else {
            // Dev checkout: resolve `node` from the login shell PATH.
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", "exec node dist/main.js"]
        }
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
            if !data.isEmpty { FileHandle.standardError.write(data) }
        }
        p.terminationHandler = { [weak self] proc in
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
        try? stdinHandle?.close() // sidecar exits on stdin close
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

    /// Returns whether the message was written to the sidecar's stdin.
    @discardableResult
    private func send(_ message: [String: Any]) -> Bool {
        guard let stdinHandle else {
            setStatus("sidecar not running — message dropped")
            return false
        }
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return false }
        data.append(0x0A)
        do {
            try stdinHandle.write(contentsOf: data)
            return true
        } catch {
            setStatus("sidecar write failed: \(error.localizedDescription)")
            return false
        }
    }

    /// store is @MainActor; send() may be called off the main thread.
    private func setStatus(_ s: String) {
        Task { @MainActor in self.store.status = s }
    }

    // MARK: inbound

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
            let created =
                (obj["trigger"] as? String)
                .flatMap { trigger in store.utterances.first { $0.id.uuidString == trigger } }?
                .time ?? Date()
            store.cards.append(
                Card(
                    id: id,
                    created: created,
                    kind: obj["kind"] as? String ?? "query",
                    title: obj["title"] as? String ?? "",
                    body: obj["body"] as? String ?? "",
                    state: obj["state"] as? String ?? "pending"))
        case "card_update":
            guard let id = obj["id"] as? String,
                let idx = store.cards.firstIndex(where: { $0.id == id })
            else { return }
            if let body = obj["body"] as? String { store.cards[idx].body = body }
            if let state = obj["state"] as? String {
                store.cards[idx].state = state
                // A follow-up answer reaching a terminal state re-enables the
                // reply field for another turn.
                if state == "done" || state == "failed" || state == "cancelled" {
                    store.cards[idx].replying = false
                }
            }
        case "usage":
            if let cost = obj["sessionCostUsd"] as? Double { store.costUsd = cost }
        case "error":
            store.status = "sidecar: \(obj["message"] as? String ?? "error")"
        default:
            break
        }
    }
}
