import Testing
@testable import Sidekick

struct GainRampTests {
    @Test func rampReachesTargetInDuration() {
        var ramp = GainRamp(sampleRate: 48_000)
        var value: Float = -1
        for _ in 0..<959 { value = ramp.next(target: 0.3) }
        #expect(value < 0.3)
        value = ramp.next(target: 0.3)
        #expect(value == 0.3)
    }

    @Test func rampStartsAtZero() {
        var ramp = GainRamp(sampleRate: 48_000)
        let first = ramp.next(target: 1)
        #expect(first > 0)
        #expect(first < 0.01)
    }

    @Test func rampIsMonotonic() {
        var ramp = GainRamp(sampleRate: 48_000)
        var previous: Float = 0
        for _ in 0..<2_000 {
            let value = ramp.next(target: 0.8)
            #expect(value >= previous)
            previous = value
        }
        for _ in 0..<2_000 {
            let value = ramp.next(target: 0.1)
            #expect(value <= previous)
            previous = value
        }
        #expect(previous == 0.1)
    }

    @Test func rampHoldsWhenAtTarget() {
        var ramp = GainRamp(sampleRate: 48_000)
        for _ in 0..<960 { _ = ramp.next(target: 0.5) }
        for _ in 0..<1_000 { #expect(ramp.next(target: 0.5) == 0.5) }
    }

    @Test func retargetMidRampReachesNewTargetInDuration() {
        var ramp = GainRamp(sampleRate: 48_000)
        for _ in 0..<480 { _ = ramp.next(target: 1) }
        var value: Float = 0
        for _ in 0..<960 { value = ramp.next(target: 0) }
        #expect(value == 0)
    }

    @Test func zeroOrBadSampleRateStepsImmediately() {
        var ramp = GainRamp(sampleRate: 0)
        #expect(ramp.next(target: 0.7) == 0.7)
    }
}
