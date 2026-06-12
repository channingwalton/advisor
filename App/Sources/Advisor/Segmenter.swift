import Foundation

/// Energy-based VAD segmenter. Feed it 16 kHz mono samples; it emits speech
/// segments after ~700 ms of trailing silence, or at an 8 s cap.
final class Segmenter {
    private let sampleRate = 16_000
    private let frameSize = 480 // 30 ms
    private let silenceFramesToEnd = 24 // ~720 ms
    private let speechFramesToStart = 3 // ~90 ms
    private let maxSegmentSamples = 16_000 * 8
    private let preRollFrames = 10 // ~300 ms kept before detected speech

    private var pending: [Float] = []
    private var preRoll: [[Float]] = []
    private var segment: [Float] = []
    private var speaking = false
    private var speechRun = 0
    private var silenceRun = 0
    private var noiseFloor: Float = 0.005

    /// Called with a completed speech segment (16 kHz mono).
    var onSegment: (([Float]) -> Void)?

    func append(_ samples: [Float]) {
        pending.append(contentsOf: samples)
        while pending.count >= frameSize {
            let frame = Array(pending.prefix(frameSize))
            pending.removeFirst(frameSize)
            process(frame: frame)
        }
    }

    /// Flush any in-progress segment (e.g. on stop).
    func flush() {
        if speaking, segment.count > frameSize * 10 {
            onSegment?(segment)
        }
        reset()
    }

    private func process(frame: [Float]) {
        let rms = sqrt(frame.reduce(0) { $0 + $1 * $1 } / Float(frame.count))
        let threshold = max(0.006, noiseFloor * 3)
        let isSpeech = rms > threshold

        if !isSpeech {
            // Adapt noise floor only during silence.
            noiseFloor = 0.95 * noiseFloor + 0.05 * rms
        }

        if speaking {
            segment.append(contentsOf: frame)
            silenceRun = isSpeech ? 0 : silenceRun + 1
            if silenceRun >= silenceFramesToEnd || segment.count >= maxSegmentSamples {
                let finished = segment
                reset()
                onSegment?(finished)
            }
        } else {
            preRoll.append(frame)
            if preRoll.count > preRollFrames { preRoll.removeFirst() }
            speechRun = isSpeech ? speechRun + 1 : 0
            if speechRun >= speechFramesToStart {
                speaking = true
                segment = preRoll.flatMap { $0 }
                silenceRun = 0
            }
        }
    }

    private func reset() {
        speaking = false
        speechRun = 0
        silenceRun = 0
        segment = []
        preRoll = []
    }
}
