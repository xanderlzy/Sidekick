import Testing
@testable import Sidekick

struct LevelMeterTests {
    private func level(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { LevelMeter.level(samples: $0) }
    }

    @Test func silenceIsZero() { #expect(level(Array(repeating: 0, count: 1024)) == 0) }
    @Test func fullScaleIsOne() { #expect(level(Array(repeating: 1, count: 1024)) == 1) }
    @Test func minus20dBIsSixTenths() {
        #expect(abs(level(Array(repeating: 0.1, count: 1024)) - 0.6) < 0.01)
    }
    @Test func emptyBufferIsZero() { #expect(level([]) == 0) }
}
