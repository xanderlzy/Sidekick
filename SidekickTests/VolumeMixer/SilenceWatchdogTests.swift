import Testing
@testable import Sidekick

struct SilenceWatchdogTests {
    private let rate = 48_000.0
    private func frames(_ seconds: Double) -> UInt64 { UInt64(seconds * 48_000) }

    @Test func firesAfterOneSecondOfZeros() {
        let dog = SilenceWatchdog()
        #expect(!dog.looksRevoked(nonZero: 3, zeroFrames: frames(0.9), sampleRate: rate))
        #expect(dog.looksRevoked(nonZero: 3, zeroFrames: frames(1), sampleRate: rate))
    }

    @Test func backsOffOneFiveThirtyWithinOneSilentRun() {
        var dog = SilenceWatchdog()
        dog.acknowledge(nonZero: 3, zeroFrames: frames(1))
        #expect(!dog.looksRevoked(nonZero: 3, zeroFrames: frames(5.9), sampleRate: rate))
        #expect(dog.looksRevoked(nonZero: 3, zeroFrames: frames(6), sampleRate: rate))
        dog.acknowledge(nonZero: 3, zeroFrames: frames(6))
        #expect(!dog.looksRevoked(nonZero: 3, zeroFrames: frames(35.9), sampleRate: rate))
        #expect(dog.looksRevoked(nonZero: 3, zeroFrames: frames(36), sampleRate: rate))
        dog.acknowledge(nonZero: 3, zeroFrames: frames(36))
        // Capped at 30 s.
        #expect(!dog.looksRevoked(nonZero: 3, zeroFrames: frames(65.9), sampleRate: rate))
        #expect(dog.looksRevoked(nonZero: 3, zeroFrames: frames(66), sampleRate: rate))
    }

    @Test func realAudioReArmsAtOneSecond() {
        var dog = SilenceWatchdog()
        dog.acknowledge(nonZero: 3, zeroFrames: frames(1))
        dog.acknowledge(nonZero: 3, zeroFrames: frames(6))
        // Non-zero audio arrived (count changed, zero run restarted).
        #expect(!dog.looksRevoked(nonZero: 4, zeroFrames: frames(0.5), sampleRate: rate))
        #expect(dog.looksRevoked(nonZero: 4, zeroFrames: frames(1), sampleRate: rate))
        dog.acknowledge(nonZero: 4, zeroFrames: frames(1))
        #expect(!dog.looksRevoked(nonZero: 4, zeroFrames: frames(5.9), sampleRate: rate))
        #expect(dog.looksRevoked(nonZero: 4, zeroFrames: frames(6), sampleRate: rate))
    }

    @Test func streamSilentFromTheStartBacksOffToo() {
        var dog = SilenceWatchdog()
        #expect(dog.looksRevoked(nonZero: 0, zeroFrames: frames(1), sampleRate: rate))
        dog.acknowledge(nonZero: 0, zeroFrames: frames(1))
        #expect(!dog.looksRevoked(nonZero: 0, zeroFrames: frames(2), sampleRate: rate))
    }
}
