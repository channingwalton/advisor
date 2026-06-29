import AVFAudio
import Foundation
import Speech

/// Apple's on-device SpeechAnalyzer/SpeechTranscriber (macOS 26+) as the STT
/// engine. Streaming with built-in endpointing — no hand-rolled VAD — and
/// resistant to hallucinating sentences from noise.
final class AppleSpeechEngine {
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

    init(name: String, locale: String = "") {
        self.name = name
        self.localeIdentifier = locale
    }

    func start(sessionToken: Int) async throws {
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

        resultsTask = Task { [weak self, name, sessionToken] in
            guard let results = self?.transcriber?.results else { return }
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
            } catch {
                appLog.write("[advisor] apple-stt(\(name)) results ended: \(error)")
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

    func stop() async {
        input?.finish()
        input = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        converter = nil
    }

    private func log(_ message: String) {
        appLog.write("[advisor] apple-stt(\(name)): \(message)")
    }
}
