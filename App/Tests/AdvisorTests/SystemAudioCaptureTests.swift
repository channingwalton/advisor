import Foundation
import Testing

@testable import Advisor

@Test func systemAudioTCCFailureUsesPermissionInstruction() {
    let error = NSError(
        domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
        code: -3801,
        userInfo: [NSLocalizedDescriptionKey: "The user declined TCCs for application, window, display capture"])

    #expect(SystemAudioCapture.startFailureNote(for: error) == SystemAudioCapture.permissionRequiredNote)
}

@Test func systemAudioNonPermissionFailureKeepsUnderlyingMessage() {
    let note = SystemAudioCapture.startFailureNote(
        for: AdvisorError.audioSetup("no display found for system audio capture"))

    #expect(note == "system audio failed: audio setup failed: no display found for system audio capture")
}

@Test func advisorAudioSetupErrorHasUsefulLocalizedDescription() {
    #expect(
        AdvisorError.audioSetup("input device has no valid format").localizedDescription
            == "audio setup failed: input device has no valid format")
}
