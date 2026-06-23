import AVFoundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

/// Captures system audio (everything the Mac plays, excluding this process)
/// via ScreenCaptureKit and delivers 16 kHz mono Float32 samples.
/// Requires Screen & System Audio Recording permission.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "advisor.sysaudio")

    /// Called on the capture queue with 16 kHz mono samples.
    var onSamples: (([Float]) -> Void)?
    var onStopped: ((Error?) -> Void)?

    static let permissionRequiredNote =
        "system audio needs Screen & System Audio Recording permission; grant it in System Settings, then relaunch"

    @MainActor
    static func requestAccessIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    static func startFailureNote(for error: Error) -> String {
        let message = error.localizedDescription
        return isPermissionFailure(message)
            ? permissionRequiredNote
            : "system audio failed: \(message)"
    }

    private static func isPermissionFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("tcc")
            || lower.contains("declined")
            || lower.contains("not authorized")
            || lower.contains("not authorised")
            || lower.contains("permission")
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw AdvisorError.audioSetup("no display found for system audio capture")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16_000
        config.channelCount = 1
        // We only want audio; make the (mandatory) video leg as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: SCStreamOutput

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid else { return }
        let samples = Self.floats(from: sampleBuffer)
        if !samples.isEmpty { onSamples?(samples) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStopped?(error)
    }

    /// Extract Float32 samples from the first (mono) channel.
    private static func floats(from sb: CMSampleBuffer) -> [Float] {
        guard
            let fd = CMSampleBufferGetFormatDescription(sb),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
            asbd.mFormatID == kAudioFormatLinearPCM,
            asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            // We request mono (channelCount = 1) and read only buffer 0. If SCK
            // ever delivered stereo/interleaved, that assumption would silently
            // mis-read; bail rather than feed garbage to STT.
            asbd.mChannelsPerFrame == 1
        else { return [] }

        var abl = AudioBufferList()
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb,
            bufferListSizeNeededOut: nil,
            bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr else { return [] }

        let buffers = UnsafeMutableAudioBufferListPointer(&abl)
        guard let first = buffers.first, let data = first.mData else { return [] }
        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
    }
}
