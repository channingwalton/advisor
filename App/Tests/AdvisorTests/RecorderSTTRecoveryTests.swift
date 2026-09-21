import Foundation
import Synchronization
import Testing

@testable import Advisor

private final class EventLog: @unchecked Sendable {
    private let events = Mutex<[String]>([])

    var values: [String] { events.withLock { $0 } }

    func append(_ event: String) {
        events.withLock { $0.append(event) }
    }

    func clear() {
        events.withLock { $0.removeAll() }
    }
}

private final class FakeSpeechEngine: SpeechEngineProtocol, @unchecked Sendable {
    var onFinal: ((String, Int) -> Void)?
    var onVolatile: ((String, Int) -> Void)?
    var onUnexpectedEnd: ((Error, Int, Int) -> Void)?

    private struct State {
        var startTokens: [(session: Int, run: Int)] = []
        var stopTotal = 0
        var activeStops = 0
        var maximumConcurrentStops = 0
        var activeTransitions = 0
        var appendsDuringTransition = 0
        var unexpectedEndOnStartRuns: Set<Int> = []
        var nextStartError: Error?
        var startDelayNanos: UInt64 = 0
        var stopDelayNanos: UInt64 = 0
        var finalOnStop: String?
    }

    private let state = Mutex(State())
    private let name: String
    private let events: EventLog

    init(name: String, events: EventLog) {
        self.name = name
        self.events = events
    }

    var starts: [(session: Int, run: Int)] {
        state.withLock { $0.startTokens }
    }

    var stopCount: Int {
        state.withLock { $0.stopTotal }
    }

    var maxConcurrentStops: Int {
        state.withLock { $0.maximumConcurrentStops }
    }

    var appendDuringTransitionCount: Int {
        state.withLock { $0.appendsDuringTransition }
    }

    func start(sessionToken: Int, runToken: Int) async throws {
        let (shouldEnd, delay, error) = state.withLock { state in
            state.startTokens.append((session: sessionToken, run: runToken))
            state.activeTransitions += 1
            let error = state.nextStartError
            state.nextStartError = nil
            return (
                state.unexpectedEndOnStartRuns.remove(runToken) != nil,
                state.startDelayNanos,
                error)
        }
        defer { state.withLock { $0.activeTransitions -= 1 } }
        events.append("\(name)-sink-start")
        if shouldEnd {
            onUnexpectedEnd?(speechHelperError(), sessionToken, runToken)
        }
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }
        if let error { throw error }
    }

    func append(_ samples: [Float]) {
        state.withLock { state in
            if state.activeTransitions > 0 { state.appendsDuringTransition += 1 }
        }
        events.append("\(name)-sink-append")
    }

    func stop() async {
        let delay = state.withLock { state in
            state.stopTotal += 1
            state.activeStops += 1
            state.activeTransitions += 1
            state.maximumConcurrentStops = max(
                state.maximumConcurrentStops, state.activeStops)
            return state.stopDelayNanos
        }
        events.append("\(name)-sink-stop")
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }
        let final = state.withLock { state -> (String, Int)? in
            guard let text = state.finalOnStop, let token = state.startTokens.last else { return nil }
            state.finalOnStop = nil
            return (text, token.session)
        }
        if let (text, token) = final { onFinal?(text, token) }
        state.withLock {
            $0.activeStops -= 1
            $0.activeTransitions -= 1
        }
    }

    func endUnexpectedly(_ error: Error, gen: Int, runToken: Int) {
        onUnexpectedEnd?(error, gen, runToken)
    }

    func endUnexpectedlyOnStart(runToken: Int) {
        _ = state.withLock { $0.unexpectedEndOnStartRuns.insert(runToken) }
    }

    func failNextStart(_ error: Error) {
        state.withLock { $0.nextStartError = error }
    }

    func setStartDelay(nanoseconds: UInt64) {
        state.withLock { $0.startDelayNanos = nanoseconds }
    }

    func setStopDelay(nanoseconds: UInt64) {
        state.withLock { $0.stopDelayNanos = nanoseconds }
    }

    func finaliseOnStop(_ text: String) {
        state.withLock { $0.finalOnStop = text }
    }
}

private final class FakeMicrophoneCapture: MicrophoneCaptureProtocol, @unchecked Sendable {
    var onSamples: (([Float]) -> Void)?

    private struct State {
        var active = false
        var starts = 0
        var stops = 0
        var emitWhileStopping = false
    }

    private let state = Mutex(State())
    private let events: EventLog

    init(events: EventLog) {
        self.events = events
    }

    var startCount: Int { state.withLock { $0.starts } }
    var stopCount: Int { state.withLock { $0.stops } }

    func start(device: InputDevice?, echoCancellation: Bool) throws {
        state.withLock {
            $0.active = true
            $0.starts += 1
        }
        events.append("mic-source-start")
    }

    func stop() {
        let (stopped, emitWhileStopping) = state.withLock { state in
            guard state.active else { return (false, false) }
            state.stops += 1
            return (true, state.emitWhileStopping)
        }
        guard stopped else { return }
        events.append("mic-source-stop")
        if emitWhileStopping { onSamples?([0.25]) }
        state.withLock { $0.active = false }
    }

    func emit(_ samples: [Float] = [0.25]) {
        let active = state.withLock { $0.active }
        if active { onSamples?(samples) }
    }

    func emitDuringNextStop() {
        state.withLock { $0.emitWhileStopping = true }
    }
}

private final class FakeSystemCapture: SystemAudioCaptureProtocol, @unchecked Sendable {
    var onSamples: (([Float]) -> Void)?
    var onStopped: ((Error?) -> Void)?

    private struct State {
        var active = false
        var starts = 0
        var stops = 0
        var emitWhileStopping = false
    }

    private let state = Mutex(State())
    private let events: EventLog

    init(events: EventLog) {
        self.events = events
    }

    var startCount: Int { state.withLock { $0.starts } }
    var stopCount: Int { state.withLock { $0.stops } }

    func start() async throws {
        state.withLock {
            $0.active = true
            $0.starts += 1
        }
        events.append("system-source-start")
    }

    func stop() async {
        let (stopped, emitWhileStopping) = state.withLock { state in
            guard state.active else { return (false, false) }
            state.stops += 1
            return (true, state.emitWhileStopping)
        }
        guard stopped else { return }
        events.append("system-source-stop")
        if emitWhileStopping { onSamples?([0.25]) }
        state.withLock { $0.active = false }
    }

    func emit(_ samples: [Float] = [0.25]) {
        let active = state.withLock { $0.active }
        if active { onSamples?(samples) }
    }

    func emitDuringNextStop() {
        state.withLock { $0.emitWhileStopping = true }
    }
}

private struct RecorderHarness {
    let store: TranscriptStore
    let recorder: Recorder
    let micEngine: FakeSpeechEngine
    let sysEngine: FakeSpeechEngine
    let micCapture: FakeMicrophoneCapture
    let systemCapture: FakeSystemCapture
    let events: EventLog
}

@MainActor
private func makeHarness(
    sessionGeneration: Int, store suppliedStore: TranscriptStore? = nil,
    requestMicPermission: @escaping @Sendable () async -> Bool = { true }
) throws -> RecorderHarness {
    let store = suppliedStore ?? TranscriptStore()
    store.sessionGeneration = sessionGeneration
    let events = EventLog()
    let micEngine = FakeSpeechEngine(name: "mic", events: events)
    let sysEngine = FakeSpeechEngine(name: "system", events: events)
    let micCapture = FakeMicrophoneCapture(events: events)
    let systemCapture = FakeSystemCapture(events: events)
    let recorder = try Recorder(
        store: store,
        micEngine: micEngine,
        sysEngine: sysEngine,
        capture: micCapture,
        systemCapture: systemCapture,
        requestMicPermission: requestMicPermission,
        requestSystemAccess: { true })
    return RecorderHarness(
        store: store,
        recorder: recorder,
        micEngine: micEngine,
        sysEngine: sysEngine,
        micCapture: micCapture,
        systemCapture: systemCapture,
        events: events)
}

@Suite(.serialized)
struct RecordingPersistenceTests {
    @MainActor
    @Test func req_recording_retry_permission() async throws {
        let permission = Mutex(false)
        let harness = try makeHarness(
            sessionGeneration: 40, requestMicPermission: { permission.withLock { $0 } })
        let control = RecordingControl(store: harness.store)
        await control.start(recorder: harness.recorder, device: nil, captureSystem: false)?.value
        #expect(harness.store.status == "microphone permission denied")
        #expect(control.state == .stopped)
        #expect(control.stoppedAt != nil)
        #expect(!control.isStarting)

        permission.withLock { $0 = true }
        let retry = try #require(control.resume(
            recorder: harness.recorder, device: nil, captureSystem: false))
        await retry.value
        #expect(control.state == .recording)
        #expect(control.stoppedAt == nil)
        #expect(harness.store.sessionGeneration == 40)
        await harness.recorder.stop().value
    }

    @MainActor
    @Test func req_recording_retry_start() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("advisor-retry-start-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try makeHarness(sessionGeneration: 41)
        let writer = SessionWriter(store: harness.store, resolveDirectory: { root })
        let control = RecordingControl(store: harness.store)
        writer.start(context: "Preserved session context")
        let url = try #require(writer.currentFileURL)
        harness.micEngine.failNextStart(speechHelperError())
        await control.start(recorder: harness.recorder, device: nil, captureSystem: false)?.value
        #expect(control.state == .stopped)
        let retry = try #require(control.resume(
            recorder: harness.recorder, device: nil, captureSystem: false))
        await retry.value
        #expect(control.state == .recording)
        #expect(writer.currentFileURL == url)
        #expect(harness.store.sessionGeneration == 41)
        harness.micEngine.onFinal?("Retry records into the original note", 41)
        await harness.recorder.stop().value
        writer.end()
        let saved = try String(contentsOf: url, encoding: .utf8)
        #expect(saved.contains("Preserved session context"))
        #expect(saved.contains("Retry records into the original note"))
    }

    @MainActor
    @Test func req_recording_retry_recovery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("advisor-retry-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try makeHarness(sessionGeneration: 42)
        let writer = SessionWriter(store: harness.store, resolveDirectory: { root })
        let control = RecordingControl(store: harness.store)
        writer.start()
        let url = try #require(writer.currentFileURL)
        await control.start(recorder: harness.recorder, device: nil, captureSystem: false)?.value
        harness.micEngine.onFinal?("Transcript before recovery failed", 42)
        await harness.recorder.drainTranscripts()
        let before = harness.store.utterances
        let run = try #require(harness.micEngine.starts.last?.run)
        harness.micEngine.failNextStart(speechHelperError())
        harness.micEngine.endUnexpectedly(speechHelperError(), gen: 42, runToken: run)
        #expect(await eventually { harness.store.status.contains("failed after restart") })
        #expect(control.state == .stopped)

        let retry = try #require(control.resume(
            recorder: harness.recorder, device: nil, captureSystem: false))
        await retry.value
        #expect(control.state == .recording)
        #expect(harness.store.utterances == before)
        #expect(harness.store.sessionGeneration == 42)
        #expect(writer.currentFileURL == url)
        harness.micEngine.onFinal?("Transcript after the successful retry", 42)
        await harness.recorder.stop().value
        writer.end()
        let saved = try String(contentsOf: url, encoding: .utf8)
        #expect(saved.contains("Transcript before recovery failed"))
        #expect(saved.contains("Transcript after the successful retry"))
    }

    @MainActor
    @Test func req_echo_short_replies() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("advisor-short-replies-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try makeHarness(sessionGeneration: 19)
        let writer = SessionWriter(store: harness.store, resolveDirectory: { root })
        writer.start()
        let url = try #require(writer.currentFileURL)
        var forwarded: [String] = []
        harness.recorder.onUtterance = { forwarded.append($0.text) }
        await startListening(harness)
        let replies = ["No.", "Yes.", "I can do it.", "Can you do it?", "Please proceed."]
        for reply in replies { harness.micEngine.onFinal?(reply, 19) }
        await harness.recorder.drainTranscripts()
        #expect(harness.store.utterances.map(\.text) == replies)
        #expect(forwarded == replies)
        writer.end()
        let saved = try String(contentsOf: url, encoding: .utf8)
        for reply in replies { #expect(saved.contains(reply)) }
        await harness.recorder.stop().value
    }

    @MainActor
    @Test func req_echo_matching_speech() async throws {
        let harness = try makeHarness(sessionGeneration: 20)
        await startListening(harness)
        let echoes = ["No.", "Yes.", "I can do it.", "Please continue the conversation."]
        for echo in echoes {
            harness.sysEngine.onFinal?(echo, 20)
            harness.micEngine.onFinal?(echo, 20)
        }
        await harness.recorder.drainTranscripts()
        #expect(harness.store.utterances.map(\.text) == echoes)
        #expect(harness.store.utterances.allSatisfy { $0.source == .them })
        await harness.recorder.stop().value
    }

    @MainActor
    @Test func req_close_mic_delay() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("advisor-close-delay-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let services = AppServices(resolveDirectory: { root })
        let harness = try makeHarness(sessionGeneration: 23, store: services.store)
        services.recorder = harness.recorder
        services.writer.start()
        let url = try #require(services.writer.currentFileURL)
        await startListening(harness)

        harness.micEngine.onFinal?("The last microphone sentence", 23)
        await services.releaseRecording().value

        #expect(try String(contentsOf: url, encoding: .utf8).contains("The last microphone sentence"))
        #expect(services.writer.currentFileURL == nil)
        #expect(services.store.utterances.isEmpty)
        #expect(services.store.sessionGeneration == 24)
    }

    @MainActor
    @Test func req_close_speech_finals() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("advisor-close-finals-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let services = AppServices(resolveDirectory: { root })
        let harness = try makeHarness(sessionGeneration: 25, store: services.store)
        services.recorder = harness.recorder
        services.writer.start()
        let url = try #require(services.writer.currentFileURL)
        await startListening(harness)
        harness.micEngine.setStopDelay(nanoseconds: 100_000_000)
        harness.micEngine.finaliseOnStop("Local final during speech teardown")
        harness.sysEngine.finaliseOnStop("Remote concluding remarks")

        let close = services.releaseRecording()
        #expect(await eventually { harness.micEngine.stopCount == 1 })
        #expect(services.isClosingRecording)
        #expect(services.writer.currentFileURL == url)
        #expect(services.store.sessionGeneration == 25)
        await close.value

        let saved = try String(contentsOf: url, encoding: .utf8)
        #expect(saved.contains("Local final during speech teardown"))
        #expect(saved.contains("Remote concluding remarks"))
        #expect(!services.isClosingRecording)
    }

    @MainActor
    @Test func req_close_generation_isolation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("advisor-close-reopen-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let services = AppServices(resolveDirectory: { root })
        let old = try makeHarness(sessionGeneration: 31, store: services.store)
        services.recorder = old.recorder
        services.writer.start(folder: "Old")
        let oldURL = try #require(services.writer.currentFileURL)
        await startListening(old)
        old.micEngine.onFinal?("Saved with the previous conversation", 31)
        services.releaseRecording()
        // This is the same barrier the reopened Recording view awaits.
        await services.recordingCloseTask?.value

        let fresh = try makeHarness(sessionGeneration: 33, store: services.store)
        services.recorder = fresh.recorder
        services.writer.start(folder: "New")
        let newURL = try #require(services.writer.currentFileURL)
        await startListening(fresh, captureSystem: false)
        old.sysEngine.onFinal?("Stale result must not cross the boundary", 31)
        await old.recorder.stop().value
        fresh.micEngine.onFinal?("Only the new conversation belongs here", 33)
        await services.releaseRecording().value

        let oldSaved = try String(contentsOf: oldURL, encoding: .utf8)
        let newSaved = try String(contentsOf: newURL, encoding: .utf8)
        #expect(oldSaved.contains("Saved with the previous conversation"))
        #expect(newSaved.contains("Only the new conversation belongs here"))
        #expect(!newSaved.contains("previous conversation"))
        #expect(!newSaved.contains("Stale result"))
    }
}

@MainActor
private func startListening(_ harness: RecorderHarness, captureSystem: Bool = true) async {
    let operation = harness.recorder.start(device: nil, captureSystem: captureSystem)
    await operation.value
    #expect(harness.store.listening)
}

@MainActor
private func eventually(_ condition: @escaping () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

private func speechHelperError() -> NSError {
    NSError(
        domain: NSCocoaErrorDomain,
        code: 4099,
        userInfo: [NSLocalizedDescriptionKey: "Couldn't communicate with a helper application."])
}

@Suite(.serialized)
struct RecorderSTTRecoveryTests {
    @MainActor
    @Test func finalSpeechIsCleanedBeforeItReachesTheTranscript() async throws {
        let harness = try makeHarness(sessionGeneration: 18)
        await startListening(harness, captureSystem: false)

        harness.micEngine.onFinal?("Um, I, I need this, uh, today.", 18)

        #expect(await eventually { harness.store.utterances.count == 1 })
        #expect(harness.store.utterances.first?.text == "I need this, today.")
    }

    @MainActor
    @Test func recoveryDrainsSourcesBeforeSinksAndRestartsSinksFirst() async throws {
        let harness = try makeHarness(sessionGeneration: 7)
        await startListening(harness)
        let oldRun = try #require(harness.micEngine.starts.last?.run)
        harness.micCapture.emitDuringNextStop()
        harness.systemCapture.emitDuringNextStop()
        harness.events.clear()

        harness.micEngine.endUnexpectedly(
            speechHelperError(), gen: 7, runToken: oldRun)

        #expect(await eventually {
            harness.store.status.contains("Apple STT restarted")
        })
        #expect(harness.events.values == [
            "mic-source-stop",
            "system-source-stop",
            "mic-sink-stop",
            "system-sink-stop",
            "mic-sink-start",
            "system-sink-start",
            "system-source-start",
            "mic-source-start",
        ])
        #expect(harness.micEngine.appendDuringTransitionCount == 0)
        #expect(harness.sysEngine.appendDuringTransitionCount == 0)
    }

    @MainActor
    @Test func simultaneousSpeechEndCoalescesToOneRestart() async throws {
        let harness = try makeHarness(sessionGeneration: 3)
        await startListening(harness)
        let oldRun = try #require(harness.micEngine.starts.last?.run)

        harness.micEngine.endUnexpectedly(
            speechHelperError(), gen: 3, runToken: oldRun)
        harness.sysEngine.endUnexpectedly(
            speechHelperError(), gen: 3, runToken: oldRun)

        #expect(await eventually {
            harness.micEngine.starts.count == 2 && harness.sysEngine.starts.count == 2
        })
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(harness.micEngine.starts.count == 2)
        #expect(harness.sysEngine.starts.count == 2)
    }

    @MainActor
    @Test func staleSpeechEndDoesNotRestart() async throws {
        let harness = try makeHarness(sessionGeneration: 11)
        await startListening(harness)
        let currentRun = try #require(harness.micEngine.starts.last?.run)

        harness.micEngine.endUnexpectedly(
            speechHelperError(), gen: 10, runToken: currentRun)

        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(harness.micEngine.starts.count == 1)
        #expect(harness.sysEngine.starts.count == 1)
    }

    @MainActor
    @Test func failedSpeechRestartStopsListeningWithClearStatus() async throws {
        let harness = try makeHarness(sessionGeneration: 4)
        await startListening(harness)
        let oldRun = try #require(harness.micEngine.starts.last?.run)
        harness.sysEngine.failNextStart(
            AdvisorError.audioSetup("speech model assets unsupported"))

        harness.micEngine.endUnexpectedly(
            speechHelperError(), gen: 4, runToken: oldRun)

        #expect(await eventually { !harness.store.listening })
        #expect(harness.store.status.contains("Apple STT failed after restart"))
        #expect(harness.micEngine.maxConcurrentStops == 1)
        #expect(harness.sysEngine.maxConcurrentStops == 1)
    }

    @MainActor
    @Test func secondFailureAfterSuccessfulRestartRetries() async throws {
        let harness = try makeHarness(sessionGeneration: 12)
        await startListening(harness)
        let initialRun = try #require(harness.micEngine.starts.last?.run)

        harness.micEngine.endUnexpectedly(
            speechHelperError(), gen: 12, runToken: initialRun)
        #expect(await eventually {
            harness.micEngine.starts.count == 2 && harness.sysEngine.starts.count == 2
        })

        let restartedRun = try #require(harness.micEngine.starts.last?.run)
        harness.micEngine.endUnexpectedly(
            speechHelperError(), gen: 12, runToken: restartedRun)

        #expect(await eventually {
            harness.micEngine.starts.count == 3 && harness.sysEngine.starts.count == 3
        })
        #expect(harness.micEngine.starts.map(\.run) == [1, 2, 3])
        #expect(harness.sysEngine.starts.map(\.run) == [1, 2, 3])
    }

    @MainActor
    @Test func stopDuringStartPreventsCaptureAndTeardownRunsOnce() async throws {
        let harness = try makeHarness(sessionGeneration: 13)
        harness.micEngine.setStartDelay(nanoseconds: 150_000_000)

        let start = harness.recorder.start(device: nil, captureSystem: true)
        #expect(await eventually { harness.micEngine.starts.count == 1 })
        let firstStop = harness.recorder.stop()
        let secondStop = harness.recorder.stop()

        await start.value
        await firstStop.value
        await secondStop.value

        #expect(!harness.store.listening)
        #expect(harness.micCapture.startCount == 0)
        #expect(harness.systemCapture.startCount == 0)
        #expect(harness.micEngine.stopCount == 1)
        #expect(harness.sysEngine.stopCount == 1)
    }

    @MainActor
    @Test func speechEndDuringStartCannotPublishDeadListeningState() async throws {
        let harness = try makeHarness(sessionGeneration: 16)
        harness.micEngine.endUnexpectedlyOnStart(runToken: 1)
        harness.micEngine.setStartDelay(nanoseconds: 100_000_000)

        let start = harness.recorder.start(device: nil, captureSystem: true)
        await start.value

        #expect(await eventually {
            harness.store.status.contains("Apple STT failed during start")
        })
        #expect(!harness.store.listening)
        #expect(harness.micCapture.startCount == 0)
        #expect(harness.systemCapture.startCount == 0)
        #expect(await eventually {
            harness.micEngine.stopCount == 1 && harness.sysEngine.stopCount == 1
        })
    }

    @MainActor
    @Test func repeatedStopDoesNotOverlapOrRepeatTeardown() async throws {
        let harness = try makeHarness(sessionGeneration: 14)
        await startListening(harness)
        harness.micEngine.setStopDelay(nanoseconds: 100_000_000)
        harness.sysEngine.setStopDelay(nanoseconds: 100_000_000)

        let firstStop = harness.recorder.stop()
        let secondStop = harness.recorder.stop()
        await firstStop.value
        await secondStop.value

        #expect(harness.micCapture.stopCount == 1)
        #expect(harness.systemCapture.stopCount == 1)
        #expect(harness.micEngine.stopCount == 1)
        #expect(harness.sysEngine.stopCount == 1)
        #expect(harness.micEngine.maxConcurrentStops == 1)
        #expect(harness.sysEngine.maxConcurrentStops == 1)
    }

    @MainActor
    @Test func stopRetainsRecorderUntilQueuedTeardownFinishes() async throws {
        let store = TranscriptStore()
        store.sessionGeneration = 17
        let events = EventLog()
        let micEngine = FakeSpeechEngine(name: "mic", events: events)
        let sysEngine = FakeSpeechEngine(name: "system", events: events)
        micEngine.setStopDelay(nanoseconds: 100_000_000)
        var recorder: Recorder? = try Recorder(
            store: store,
            micEngine: micEngine,
            sysEngine: sysEngine,
            capture: FakeMicrophoneCapture(events: events),
            systemCapture: FakeSystemCapture(events: events),
            requestMicPermission: { true },
            requestSystemAccess: { true })
        weak let weakRecorder = recorder
        var start: Task<Void, Never>? = recorder?.start(
            device: nil, captureSystem: true)
        await start?.value
        start = nil

        var stop: Task<Void, Never>? = recorder?.stop()
        recorder = nil

        #expect(weakRecorder != nil)
        await stop?.value
        stop = nil
        #expect(await eventually { weakRecorder == nil })
    }

    @MainActor
    @Test func failureDuringRestartSerialisesCleanup() async throws {
        let harness = try makeHarness(sessionGeneration: 15)
        await startListening(harness)
        let oldRun = try #require(harness.micEngine.starts.last?.run)
        harness.micEngine.endUnexpectedlyOnStart(runToken: oldRun + 1)
        harness.micEngine.setStartDelay(nanoseconds: 100_000_000)
        harness.micEngine.setStopDelay(nanoseconds: 50_000_000)

        harness.micEngine.endUnexpectedly(
            speechHelperError(), gen: 15, runToken: oldRun)

        #expect(await eventually { !harness.store.listening })
        #expect(await eventually {
            harness.store.status.contains("Apple STT failed after restart")
        })
        #expect(await eventually {
            harness.micEngine.stopCount == 2 && harness.sysEngine.stopCount == 2
        })
        #expect(harness.micEngine.maxConcurrentStops == 1)
        #expect(harness.sysEngine.maxConcurrentStops == 1)
        #expect(harness.micEngine.stopCount == 2)
        #expect(harness.sysEngine.stopCount == 2)
        #expect(harness.systemCapture.startCount == 1)
        #expect(harness.micCapture.startCount == 1)
    }
}
