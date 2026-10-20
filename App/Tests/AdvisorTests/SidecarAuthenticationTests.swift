import Foundation
import Testing
@testable import Advisor

@MainActor
private final class AuthHarness {
    let store = TranscriptStore()
    var config = AdvisorConfig()
    var keys: [Keychain.Key: String] = [:]
    var children: [Process] = []
    var outputWriters: [FileHandle] = []
    var environment: [String: String] = [:]
    let directory: URL
    var useDevShell = false
    /// What the fake sidecar runs; the default reads stdin until it closes.
    var childScript = AuthHarness.childScript

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("advisor-auth-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    lazy var manager = SidecarManager(
        store: store,
        loadConfig: { [unowned self] in self.config },
        readKey: { [unowned self] in self.keys[$0] },
        launchProcess: { [unowned self] process in
            // Real harmless subprocess: retain production pipes, environment
            // and termination callbacks without Node, providers or Keychain.
            if !self.useDevShell {
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", self.childScript]
            }
            var environment = process.environment ?? [:]
            environment["ADVISOR_TEST_ENV"] = self.envFile(self.children.count).path
            environment["ADVISOR_TEST_INPUT"] = self.inputFile(self.children.count).path
            process.environment = environment
            let outputPipe = process.standardOutput as! Pipe
            let output = FileHandle(
                fileDescriptor: dup(outputPipe.fileHandleForWriting.fileDescriptor), closeOnDealloc: true)
            try process.run()
            self.children.append(process)
            self.outputWriters.append(output)
        },
        environment: environment,
        exitGrace: exitGrace,
        healthyRunSeconds: healthyRunSeconds,
        restartDelay: { [unowned self] _ in self.restartDelay }
    )
    /// Fast in tests: the crash path's logic is under test, not its timing.
    var restartDelay: TimeInterval = 0.01
    var healthyRunSeconds: TimeInterval = 60

    func messageTypes(_ child: Int) -> [String] {
        messages(child).compactMap { $0["type"] as? String }
    }
    /// The production default; a test of the backstop's timing sets it short
    /// before first touching `manager`.
    var exitGrace: TimeInterval = 2

    static let childScript = """
        printf '%s\\n%s\\n' "${ANTHROPIC_API_KEY-unset}" "${OPENAI_API_KEY-unset}" > "$ADVISOR_TEST_ENV"
        while IFS= read -r line; do
            printf '%s\\n' "$line" >> "$ADVISOR_TEST_INPUT"
        done
        """

    func envFile(_ child: Int) -> URL { directory.appendingPathComponent("env-\(child)") }
    func inputFile(_ child: Int) -> URL { directory.appendingPathComponent("input-\(child)") }

    func messages(_ child: Int) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: inputFile(child)) else { return [] }
        return SidecarManager.ndjsonFrames(data).frames.compactMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
    }

    func close() {
        manager.stop()
        for child in children {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        for output in outputWriters { try? output.close() }
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Polls `predicate` every 5 ms, for 0.5 s by default; `seconds` for a path
/// that spawns several children in a row (the crash loop).
@MainActor
private func waitFor(seconds: Double = 0.5, _ predicate: () -> Bool) async -> Bool {
    for _ in 0..<Int(seconds * 200) {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return predicate()
}

@MainActor
@Test func req_sidecar_auth_refresh_nextSessionUsesChangedModeKeyAndProvider() throws {
    let h = try AuthHarness()
    defer { h.close() }
    h.manager.start()
    #expect(h.children.count == 1)
    #expect(h.children[0].environment?["ANTHROPIC_API_KEY"] == nil)

    h.config.authMode = "apiKey"
    h.keys[.anthropic] = "placeholder-anthropic-one"
    h.manager.sendSessionStart("api-session")
    try #require(h.children.count == 2)
    #expect(h.children[1].environment?["ANTHROPIC_API_KEY"] == "placeholder-anthropic-one")

    h.keys[.anthropic] = "placeholder-anthropic-two"
    h.manager.sendSessionEnd()
    h.manager.sendSessionStart("replacement-key-session")
    try #require(h.children.count == 3)
    #expect(h.children[2].environment?["ANTHROPIC_API_KEY"] == "placeholder-anthropic-two")

    h.config.provider = "codex"
    h.keys[.openai] = "placeholder-openai"
    h.manager.sendSessionEnd()
    h.manager.sendSessionStart("different-provider-session")
    try #require(h.children.count == 4)
    #expect(h.children[3].environment?["OPENAI_API_KEY"] == "placeholder-openai")
    #expect(h.children[3].environment?["ANTHROPIC_API_KEY"] == nil)
}

@MainActor
@Test func req_sidecar_auth_subscription_removesInheritedAndPreviousProviderOverrides() throws {
    let h = try AuthHarness()
    defer { h.close() }
    h.environment = ["ANTHROPIC_API_KEY": "inherited-anthropic", "OPENAI_API_KEY": "inherited-openai"]
    h.manager.start()
    #expect(h.children[0].environment?["ANTHROPIC_API_KEY"] == nil)
    #expect(h.children[0].environment?["OPENAI_API_KEY"] == nil)

    h.config.authMode = "apiKey"
    h.keys[.anthropic] = "placeholder-key"
    h.manager.sendSessionStart("api-key")
    try #require(h.children.count == 2)
    h.config.authMode = "subscription"
    h.manager.sendSessionStart("subscription")
    try #require(h.children.count == 3)
    #expect(h.children[2].environment?["ANTHROPIC_API_KEY"] == nil)
    #expect(h.children[2].environment?["OPENAI_API_KEY"] == nil)
}

@MainActor
@Test func req_sidecar_auth_stable_preservesProcessAndReplaysConfigBeforeSession() async throws {
    let h = try AuthHarness()
    defer { h.close() }
    h.manager.start()
    h.manager.sendLanes(3)
    h.manager.sendAuto(false)
    h.manager.sendSessionStart("first")
    h.manager.sendSessionEnd()
    h.manager.sendSessionStart("second")
    #expect(h.children.count == 1)

    h.config.authMode = "apiKey"
    h.keys[.anthropic] = "placeholder-key"
    h.manager.sendSessionStart("refreshed", context: "context")
    try #require(h.children.count == 2)
    #expect(await waitFor { h.messages(1).count == 3 })
    let frames = h.messages(1)
    try #require(frames.count == 3)
    #expect(frames.map { $0["type"] as? String } == ["config", "config", "session_start"])
    #expect(frames[0]["lanes"] as? Int == 3)
    #expect(frames[1]["auto"] as? Bool == false)
    #expect(frames[2]["sessionId"] as? String == "refreshed")
    #expect(frames[2]["context"] as? String == "context")
    #expect(!(try String(contentsOf: h.inputFile(1), encoding: .utf8)).contains("placeholder-key"))
    h.manager.sendSessionEnd()
    h.manager.sendSessionStart("same-key")
    #expect(h.children.count == 2)
}

@MainActor
@Test func req_sidecar_auth_generation_ignoresReplacedProcessCallbacksAndPendingRetries() async throws {
    let h = try AuthHarness()
    defer { h.close() }
    h.manager.start()
    let old = h.children[0]
    let oldTermination = try #require(old.terminationHandler)
    let oldOutput = try #require((old.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler)
    h.config.authMode = "apiKey"
    h.keys[.anthropic] = "placeholder-key"
    h.manager.sendSessionStart("replacement")
    try #require(h.children.count == 2)
    #expect(await waitFor { !old.isRunning })

    var states: [String] = []
    let request = try #require(h.manager.askDocument(question: "question", document: "doc") {
        _, state in states.append(state)
    })
    let stalePipe = Pipe()
    try stalePipe.fileHandleForWriting.write(contentsOf: Data(
        "{\"type\":\"card\",\"id\":\"stale\"}\n".utf8))
    oldOutput(stalePipe.fileHandleForReading)
    oldTermination(old)
    await Task.yield()
    #expect(states.isEmpty)
    #expect(h.store.cards.isEmpty)
    #expect(h.manager.askDocument(question: "still connected", document: "doc") { _, _ in } != nil)
    try h.outputWriters[1].write(contentsOf: Data(
        "{\"type\":\"document_answer\",\"id\":\"\(request)\",\"body\":\"answer\",\"state\":\"done\"}\n".utf8))
    #expect(await waitFor { states == ["done"] })

    // A genuine crash schedules backoff. Starting the next session replaces it
    // immediately, so that already-scheduled retry must become a no-op.
    h.children[1].terminate()
    #expect(await waitFor { h.store.status.contains("restarting") })
    h.manager.sendSessionStart("during-backoff")
    try #require(h.children.count == 3)
    try await Task.sleep(for: .milliseconds(1150))
    #expect(h.children.count == 3)
}

@MainActor
@Test func sidecarAuthenticationSurvivesDevLoginProfileOverrides() async throws {
    let h = try AuthHarness()
    defer { h.close() }
    h.useDevShell = true
    h.environment = ["ZDOTDIR": h.directory.path, "PATH": "/usr/bin:/bin"]
    let profile = """
        export PATH="\(h.directory.path):/usr/bin:/bin"
        export ANTHROPIC_API_KEY=profile-anthropic
        export OPENAI_API_KEY=profile-openai
        """
    try profile.write(to: h.directory.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
    let node = h.directory.appendingPathComponent("node")
    try ("#!/bin/sh\n" + AuthHarness.childScript).write(to: node, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: node.path)
    h.manager.start()
    #expect(await waitFor { FileManager.default.fileExists(atPath: h.envFile(0).path) })
    #expect(try String(contentsOf: h.envFile(0), encoding: .utf8) == "unset\nunset\n")

    h.config.authMode = "apiKey"
    h.keys[.anthropic] = "selected-placeholder"
    h.manager.sendSessionStart("selected")
    try #require(h.children.count == 2)
    #expect(await waitFor { FileManager.default.fileExists(atPath: h.envFile(1).path) })
    #expect(try String(contentsOf: h.envFile(1), encoding: .utf8) == "selected-placeholder\nunset\n")
    #expect(!h.children[1].arguments!.joined().contains("selected-placeholder"))
}

// The shutdown contract: the app closes the sidecar's stdin and the sidecar
// exits on its own, through Node's exit handlers (where the Agent SDK kills the
// CLI processes it spawned). SIGTERM skips those, so it is only the backstop.

@MainActor
@Test func req_sidecar_shutdown_closesStdinAndLetsTheSidecarExitCleanly() async throws {
    let h = try AuthHarness()
    defer { h.close() }
    h.manager.start()
    let child = h.children[0]
    h.manager.stop()
    try #require(await waitFor { !child.isRunning }) // reading the reason of a live process raises
    // It left on stdin close, not by signal.
    #expect(child.terminationReason == .exit)
    #expect(child.terminationStatus == 0)
}

@MainActor
@Test func req_sidecar_shutdown_terminatesASidecarThatIgnoresStdinClose() async throws {
    let h = try AuthHarness()
    defer { h.close() }
    h.childScript = "exec sleep 30" // never reads stdin
    h.exitGrace = 0.2
    h.manager.start()
    let child = h.children[0]
    h.manager.stop()
    try await Task.sleep(for: .milliseconds(50))
    #expect(child.isRunning, "no signal before the grace period")
    try await Task.sleep(for: .seconds(h.exitGrace))
    try #require(await waitFor { !child.isRunning })
    #expect(child.terminationReason == .uncaughtSignal)
}

// ⌘Q exits the app synchronously after finishQuit, so the delayed backstop
// could never fire there: the quit path waits, bounded, for the clean exit.

@MainActor
@Test func req_sidecar_shutdown_quitWaitsForTheCleanExit() throws {
    let h = try AuthHarness()
    defer { h.close() }
    h.manager.start()
    let child = h.children[0]
    let t0 = Date()
    h.manager.stopForExit()
    let elapsed = Date().timeIntervalSince(t0)
    try #require(!child.isRunning)
    #expect(child.terminationReason == .exit)
    #expect(elapsed < 1, "left on stdin close, well inside the wait")
}

@MainActor
@Test func req_sidecar_shutdown_quitTerminatesASidecarThatIgnoresStdinClose() throws {
    let h = try AuthHarness()
    defer { h.close() }
    h.childScript = "exec sleep 30"
    h.manager.start()
    let child = h.children[0]
    h.manager.stopForExit(waitingUpTo: 0.2)
    #expect(child.isRunning || child.terminationReason == .uncaughtSignal) // terminate() is asynchronous
    child.waitUntilExit()
    #expect(child.terminationReason == .uncaughtSignal)
}

/// A question asked before Listen keeps its card into the session (issue #104).
/// Listen on the same login lets the sidecar finish it; Listen after a login
/// change replaces the sidecar, which can never finish it, so it fails rather
/// than spinning.
@MainActor
@Test func req_sidecar_auth_refresh_failsCardsTheReplacedSidecarWasAnswering() async throws {
    let h = try AuthHarness()
    defer { h.close() }
    h.manager.start()
    h.store.cards = [Card(id: "c1", created: Date(), kind: "query", title: "Q", body: "…", state: "streaming")]

    h.manager.sendSessionStart("same-login")
    #expect(h.children.count == 1)
    #expect(h.store.cards[0].state == "streaming", "the running sidecar finishes it")

    h.config.authMode = "apiKey"
    h.keys[.anthropic] = "placeholder-anthropic"
    h.manager.sendSessionEnd()
    let note = EditorialNote(id: UUID(), time: Date(), text: "Bob is the CFO")
    h.manager.sendSessionStart("changed-login", notes: [note])
    try #require(h.children.count == 2)
    #expect(h.store.cards[0].state == "failed")
    // The replacement is told the notes typed before Listen, after the start
    // that clears its transcript.
    #expect(await waitFor { h.messageTypes(1).last == "note" })
    #expect(h.messageTypes(1).suffix(2) == ["session_start", "note"], "\(h.messageTypes(1))")
}

// Crash recovery (DESIGN.md: SidecarManager), pinned at the manager level —
// before, only Card.apply and the backoff-replaced-by-a-new-session case were
// covered (code review 2026-10-17).

@MainActor
@Test func req_sidecar_crash_failsInFlightCardsAndReplaysTheSessionOnRestart() async throws {
    let h = try AuthHarness()
    defer { h.close() }
    h.manager.start()
    h.manager.sendLanes(2)
    h.manager.sendAuto(true)
    h.manager.sendSessionStart("s1", context: "the context")
    h.store.cards = [Card(id: "c1", created: Date(), kind: "answer", title: "t", body: "…", state: "streaming")]
    h.children[0].terminate() // a crash, from the manager's point of view
    #expect(await waitFor { h.store.status.contains("restarting (1/5)") })
    #expect(h.store.cards[0].state == "failed", "a card the dead sidecar can never finish")
    #expect(await waitFor { h.children.count == 2 })
    // The replacement is told what the running conversation depends on, in order.
    #expect(await waitFor { h.messageTypes(1).contains("session_start") })
    #expect(h.messageTypes(1) == ["config", "config", "session_start"], "\(h.messageTypes(1))")
    let start = h.messages(1).last { $0["type"] as? String == "session_start" }
    #expect(start?["sessionId"] as? String == "s1")
    #expect(start?["context"] as? String == "the context")
}

@MainActor
@Test func req_sidecar_crash_exhaustsTheRestartBudgetInACrashLoop() async throws {
    let h = try AuthHarness()
    defer { h.close() }
    h.childScript = "exit 7" // dies at once, every time
    h.manager.start()
    // Six spawns, six terminations and five backoffs: generous on a loaded runner.
    #expect(await waitFor(seconds: 5) { h.store.status.contains("restart attempts exhausted") })
    #expect(h.children.count == 6, "the first spawn plus five restarts: \(h.children.count)")
    #expect(h.store.status.contains("sidecar crashed (7)"))
    #expect(h.store.status.contains("stop and start listening again"))
}

@MainActor
@Test func req_sidecar_crash_aHealthyRunResetsTheBudget() async throws {
    let h = try AuthHarness()
    defer { h.close() }
    // Crashes within the window count towards the budget; one after it resets
    // the budget. The window is wide enough that a crash right after spawn is
    // inside it even on a loaded runner, and the "healthy" run is longer still.
    h.healthyRunSeconds = 0.5
    h.manager.start()
    h.children[0].terminate()
    #expect(await waitFor { h.children.count == 2 })
    h.children[1].terminate()
    #expect(await waitFor { h.store.status.contains("restarting (2/5)") })
    #expect(await waitFor { h.children.count == 3 })
    try await Task.sleep(for: .milliseconds(700)) // a healthy run
    h.children[2].terminate()
    #expect(await waitFor { h.store.status.contains("restarting (1/5)") })
}
