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
private func makeHarness(sessionGeneration: Int) throws -> RecorderHarness {
    let store = TranscriptStore()
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
        requestMicPermission: { true },
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
