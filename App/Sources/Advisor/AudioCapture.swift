import AudioToolbox
import AVFoundation
import CoreAudio

/// Captures microphone audio and delivers 16 kHz mono Float32 samples.
final class AudioCapture {
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?

    /// Called on the audio thread with 16 kHz mono samples.
    var onSamples: (([Float]) -> Void)?

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// The system default input device, or nil if it can't be read. Used to skip a
    /// redundant (and on macOS 26, input-wedging) device switch when the chosen
    /// device is already the default.
    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return err == noErr ? id : nil
    }

    /// - Parameter echoCancellation: enable Apple voice processing (AEC) so
    ///   speaker output (e.g. call audio) is removed from the mic signal.
    ///   Voice processing fails on some output devices (e.g. multichannel
    ///   Studio Display speakers, error -10875), so failures fall back to
    ///   plain capture without AEC.
    func start(deviceID: AudioDeviceID? = nil, echoCancellation: Bool = false) throws {
        do {
            try doStart(deviceID: deviceID, echoCancellation: echoCancellation)
        } catch where echoCancellation {
            appLog.write("[advisor] AEC start failed (\(error)); retrying without AEC")
            try doStart(deviceID: deviceID, echoCancellation: false)
        }
    }

    private func doStart(deviceID: AudioDeviceID?, echoCancellation: Bool) throws {
        // Fresh engine every attempt: a failed voice-processing init leaves
        // the old engine's input unit delivering silence even after disabling.
        engine.stop()
        engine = AVAudioEngine()
        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(echoCancellation)
        } catch {
            if echoCancellation {
                throw AdvisorError.audioSetup("voice processing unavailable: \(error)")
            }
        }
        // `inputNode` is already bound to the system default input, so only switch
        // the AU's device when the user picked a *different* one. Redundantly
        // setting CurrentDevice to the device that is already the default wedges
        // the input on macOS 26 — the engine runs and reports a valid format, but
        // the tap never fires (no buffers at all). Selecting a genuine non-default
        // device still goes through the set.
        if var deviceID, deviceID != Self.defaultInputDeviceID(), let au = input.audioUnit {
            let err = AudioUnitSetProperty(
                au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard err == noErr else {
                throw AdvisorError.audioSetup("cannot select input device \(deviceID): \(err)")
            }
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else {
            throw AdvisorError.audioSetup("input device has no valid format")
        }
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw AdvisorError.audioSetup("cannot create 16 kHz converter from \(inFormat)")
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            let ratio = outFormat.sampleRate / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

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
            guard convError == nil, out.frameLength > 0, let ch = out.floatChannelData else { return }
            self.onSamples?(Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength))))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Discard the whole engine; the retry builds a fresh one.
            input.removeTap(onBus: 0)
            engine.stop()
            self.converter = nil
            throw error
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
    }
}

enum AdvisorError: Error, CustomStringConvertible, LocalizedError {
    case audioSetup(String)

    var description: String {
        switch self {
        case .audioSetup(let m): "audio setup failed: \(m)"
        }
    }

    var errorDescription: String? { description }
}
