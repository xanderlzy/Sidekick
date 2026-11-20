import Testing
@testable import Sidekick

struct AudioCaptureTests {
    @Test func rejectsUnusableInputFormats() {
        #expect(!AudioCapture.isUsable(sampleRate: 0, channels: 1))
        #expect(!AudioCapture.isUsable(sampleRate: 48_000, channels: 0))
        #expect(AudioCapture.isUsable(sampleRate: 48_000, channels: 1))
    }
}
