import AVFAudio
import Foundation
import Speech

protocol SpeechEngineProtocol: AnyObject, Sendable {
    var onFinal: ((String, Int) -> Void)? { get set }
    var onVolatile: ((String, Int) -> Void)? { get set }
    var onUnexpectedEnd: ((Error, Int, Int) -> Void)? { get set }

    func start(sessionToken: Int, runToken: Int) async throws
    func append(_ samples: [Float])
    func stop() async
}

/// Apple's on-device SpeechAnalyzer/SpeechTranscriber (macOS 26+) as the STT
/// engine. Streaming with built-in endpointing — no hand-rolled VAD — and
/// resistant to hallucinating sentences from noise.
final class AppleSpeechEngine: SpeechEngineProtocol, @unchecked Sendable {
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?
    private let name: String
    private let localeIdentifier: String

    private let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// Finalised utterance text, tagged with the session token from `start`.
    var onFinal: ((String, Int) -> Void)?
    /// In-progress (volatile) text for the current utterance; superseded by
    /// onFinal. Tagged with the session token from `start`.
    var onVolatile: ((String, Int) -> Void)?
    /// Unexpected result-stream failure, tagged with the session token from
    /// `start` so the recorder can ignore stale failures after stop/restart.
    var onUnexpectedEnd: ((Error, Int, Int) -> Void)?

    init(name: String, locale: String = "") {
        self.name = name
        self.localeIdentifier = locale
    }

    func start(sessionToken: Int, runToken: Int) async throws {
        // start() isn't re-entrant: dispose any prior engine before creating new
        // state, so a second start() without an intervening stop() (issue #48)
        // doesn't leak the previous continuation/resultsTask. No-op when fresh.
        await teardown()
        guard SpeechTranscriber.isAvailable else {
            throw AdvisorError.audioSetup("SpeechTranscriber unavailable on this OS")
        }
        // "" follows the device default; otherwise honour the configured id.
        let requested = localeIdentifier.isEmpty
            ? Locale.current : Locale(identifier: localeIdentifier)
        guard
            let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
        else {
            throw AdvisorError.audioSetup("no supported transcription locale")
        }
        // Volatile results stream words as they're recognised; finals replace them.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [])

        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            break
        case .supported, .downloading:
            log("downloading speech model assets…")
            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        default:
            throw AdvisorError.audioSetup("speech model assets unsupported")
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber])
        if let fmt = analyzerFormat, fmt != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: fmt)
        }

        let (sequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        try await analyzer.start(inputSequence: sequence)
        self.analyzer = analyzer
        self.transcriber = transcriber

        // Capture this run's transcriber directly. Teardown may nil the
        // lifecycle-owned property before this task first executes.
        resultsTask = Task { [weak self, name, sessionToken, runToken, transcriber] in
            let results = transcriber.results
            do {
                for try await result in results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    if result.isFinal {
                        self?.onFinal?(text, sessionToken)
                    } else {
                        self?.onVolatile?(text, sessionToken)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                appLog.write("[advisor] apple-stt(\(name)) results ended: \(error)")
                self?.onUnexpectedEnd?(error, sessionToken, runToken)
            }
        }
        log("ready (locale \(locale.identifier))")
    }

    /// Feed 16 kHz mono samples (any thread).
    func append(_ samples: [Float]) {
        guard let input else { return }
        // An empty buffer makes baseAddress nil → force-unwrap crash below.
        guard !samples.isEmpty else { return }
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        if let converter, let analyzerFormat {
            let ratio = analyzerFormat.sampleRate / sourceFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity)
            else { return }
            var consumed = false
            var convError: NSError?
            converter.convert(to: out, error: &convError) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard convError == nil, out.frameLength > 0 else { return }
            input.yield(AnalyzerInput(buffer: out))
        } else {
            input.yield(AnalyzerInput(buffer: buffer))
        }
    }

    /// Idempotent teardown of the running engine: finish input, finalise+finish
    /// the analyzer, drain the results task, and drop analyzer/transcriber/
    /// converter. All optional-chained, so on a fresh engine it's a cheap no-op.
    /// Shared by stop() and the top of start() — a re-entrant start (issue #48)
    /// must dispose the prior engine first, else the orphaned resultsTask keeps
    /// decoding the old transcriber and fires stale onFinal/onVolatile callbacks.
    private func teardown() async {
        input?.finish()
        input = nil
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            // A failed finalisation may not finish the results sequence.
            resultsTask?.cancel()
        }
        // Finalisation can return before the consumer delivers its last finals.
        // Cancelling it here used to discard those results during window close.
        await resultsTask?.value
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        converter = nil
    }

    func stop() async {
        await teardown()
    }

    private func log(_ message: String) {
        appLog.write("[advisor] apple-stt(\(name)): \(message)")
    }
}
