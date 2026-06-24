import AudioToolbox
import AVFoundation
import CoreAudio
import CoreMedia

/// Captures microphone audio and delivers 16 kHz mono Float32 samples.
final class AudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    enum CaptureBackend: Equatable {
        case avAudioEngineDefault
        case avCaptureSessionDevice
    }

    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let captureQueue = DispatchQueue(label: "advisor.mic.capture")
    private var captureSession: AVCaptureSession?
    private var captureOutput: AVCaptureAudioDataOutput?
    private var loggedUnsupportedCaptureFormat = false

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

    static func captureBackend(
        for deviceID: AudioDeviceID?,
        defaultDeviceID: AudioDeviceID?
    ) -> CaptureBackend {
        guard let deviceID else { return .avAudioEngineDefault }
        guard let defaultDeviceID else { return .avCaptureSessionDevice }
        return deviceID == defaultDeviceID ? .avAudioEngineDefault : .avCaptureSessionDevice
    }

    /// - Parameter echoCancellation: enable Apple voice processing (AEC) so
    ///   speaker output (e.g. call audio) is removed from the mic signal.
    ///   Voice processing fails on some output devices (e.g. multichannel
    ///   Studio Display speakers, error -10875), so failures fall back to
    ///   plain capture without AEC.
    func start(device: InputDevice? = nil, echoCancellation: Bool = false) throws {
        do {
            try doStart(device: device, echoCancellation: echoCancellation)
        } catch where echoCancellation {
            appLog.write("[advisor] AEC start failed (\(error)); retrying without AEC")
            try doStart(device: device, echoCancellation: false)
        }
    }

    private func doStart(device: InputDevice?, echoCancellation: Bool) throws {
        stop()
        switch Self.captureBackend(for: device?.id, defaultDeviceID: Self.defaultInputDeviceID()) {
        case .avAudioEngineDefault:
            try startDefaultEngine(echoCancellation: echoCancellation)
        case .avCaptureSessionDevice:
            guard let device else {
                throw AdvisorError.audioSetup("missing selected input device")
            }
            if echoCancellation {
                appLog.write("[advisor] AEC unavailable for selected non-default mic; using plain capture")
            }
            try startCaptureSession(device: device)
        }
    }

    private func startDefaultEngine(echoCancellation: Bool) throws {
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

    private func startCaptureSession(device: InputDevice) throws {
        guard let captureDevice = Self.captureDevice(matching: device) else {
            throw AdvisorError.audioSetup("cannot find input device \(device.name) for capture")
        }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: captureDevice)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: captureQueue)

        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw AdvisorError.audioSetup("cannot add input device \(device.name)")
        }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw AdvisorError.audioSetup("cannot add mic capture output")
        }
        session.addOutput(output)
        session.commitConfiguration()

        captureSession = session
        captureOutput = output
        loggedUnsupportedCaptureFormat = false
        captureQueue.sync { session.startRunning() }
        appLog.write("[advisor] mic capture using AVCaptureSession: \(device.name)")
    }

    private static func captureDevice(matching device: InputDevice) -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
        if let uid = device.uid, let match = devices.first(where: { $0.uniqueID == uid }) {
            return match
        }
        return devices.first { $0.localizedName == device.name }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard sampleBuffer.isValid else { return }
        let samples = Self.floats(from: sampleBuffer)
        guard !samples.isEmpty else {
            logUnsupportedCaptureFormatOnce(sampleBuffer)
            return
        }
        onSamples?(samples)
    }

    private func logUnsupportedCaptureFormatOnce(_ sampleBuffer: CMSampleBuffer) {
        guard !loggedUnsupportedCaptureFormat else { return }
        loggedUnsupportedCaptureFormat = true
        let description = Self.audioFormatDescription(sampleBuffer) ?? "unknown"
        appLog.write("[advisor] mic capture ignored unsupported sample format: \(description)")
    }

    private static func audioFormatDescription(_ sampleBuffer: CMSampleBuffer) -> String? {
        guard
            let fd = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee
        else { return nil }
        return "format=\(asbd.mFormatID) flags=\(asbd.mFormatFlags) rate=\(asbd.mSampleRate) channels=\(asbd.mChannelsPerFrame)"
    }

    private static func floats(from sampleBuffer: CMSampleBuffer) -> [Float] {
        guard
            let fd = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
            asbd.mFormatID == kAudioFormatLinearPCM,
            asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            asbd.mChannelsPerFrame == 1,
            asbd.mSampleRate == 16_000
        else { return [] }

        var needed = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &needed,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil)
        guard status == noErr, needed > 0 else { return [] }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        var blockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: raw.assumingMemoryBound(to: AudioBufferList.self),
            bufferListSize: needed,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr else { return [] }

        let buffers = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        guard let first = buffers.first, let data = first.mData else { return [] }
        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
    }

    func stop() {
        let session = captureSession
        captureSession = nil
        captureOutput?.setSampleBufferDelegate(nil, queue: nil)
        captureOutput = nil
        if let session {
            captureQueue.sync { session.stopRunning() }
        }
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
