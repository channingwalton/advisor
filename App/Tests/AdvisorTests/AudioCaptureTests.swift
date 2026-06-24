import CoreAudio
import Testing

@testable import Advisor

@Test func audioCaptureUsesEngineForDefaultInput() {
    let defaultID = AudioDeviceID(10)

    #expect(
        AudioCapture.captureBackend(for: defaultID, defaultDeviceID: defaultID)
            == .avAudioEngineDefault)
}

@Test func audioCaptureUsesCaptureSessionForNonDefaultInput() {
    #expect(
        AudioCapture.captureBackend(for: AudioDeviceID(11), defaultDeviceID: AudioDeviceID(10))
            == .avCaptureSessionDevice)
}

@Test func audioCaptureUsesCaptureSessionWhenDefaultCannotBeRead() {
    #expect(
        AudioCapture.captureBackend(for: AudioDeviceID(11), defaultDeviceID: nil)
            == .avCaptureSessionDevice)
}

@Test func audioCaptureUsesEngineForUnspecifiedInput() {
    #expect(
        AudioCapture.captureBackend(for: nil, defaultDeviceID: AudioDeviceID(10))
            == .avAudioEngineDefault)
}
