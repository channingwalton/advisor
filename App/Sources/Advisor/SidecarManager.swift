import Foundation

struct Card: Identifiable, Equatable {
    let id: String
    let created: Date
    var kind: String
    var title: String
    var body: String
    var state: String // pending | streaming | done | failed | cancelled
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
    private var lastSessionId: String?
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
        } catch {
            Task { @MainActor in self.store.status = "sidecar failed to start: \(error)" }
        }
    }

    @MainActor
    private func handleTermination(_ code: Int32) {
        stdinHandle = nil
        process = nil
        if stopping { stopping = false; return } // deliberate stop()
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
        if let lastSessionId { sendSessionStart(lastSessionId) }
    }

    func stop() {
        stopping = true
        lastSessionId = nil
        try? stdinHandle?.close() // sidecar exits on stdin close
        stdinHandle = nil
        if let process, process.isRunning { process.terminate() } // backstop: no orphan
        process = nil
    }

    // MARK: outbound

    func sendSessionStart(_ id: String) {
        lastSessionId = id
        send(["type": "session_start", "sessionId": id, "ts": Date().timeIntervalSince1970])
    }

    func sendSessionEnd() {
        lastSessionId = nil // nothing to replay after the session ends
        send(["type": "session_end"])
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

    func sendLanes(_ count: Int) {
        lastLanes = count
        send(["type": "config", "lanes": count])
    }

    private func send(_ message: [String: Any]) {
        guard let stdinHandle else {
            setStatus("sidecar not running — message dropped")
            return
        }
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        do {
            try stdinHandle.write(contentsOf: data)
        } catch {
            setStatus("sidecar write failed: \(error.localizedDescription)")
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
            if let state = obj["state"] as? String { store.cards[idx].state = state }
        case "usage":
            if let cost = obj["sessionCostUsd"] as? Double { store.costUsd = cost }
        case "error":
            store.status = "sidecar: \(obj["message"] as? String ?? "error")"
        default:
            break
        }
    }
}
