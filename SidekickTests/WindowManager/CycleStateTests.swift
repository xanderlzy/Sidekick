import Testing
import CoreGraphics
@testable import Sidekick

struct CycleStateTests {
    let f = CGRect(x: 0, y: 25, width: 800, height: 900)
    let w: AnyHashable = 1

    @Test func firstPressIsStepZero() {
        var s = CycleState()
        #expect(s.step(for: .leftHalf, window: w, currentFrame: f) == 0)
    }

    @Test func repeatSameActionAdvances() {
        var s = CycleState()
        s.didSet(f, for: .leftHalf, window: w)
        #expect(s.step(for: .leftHalf, window: w, currentFrame: f) == 1)
        s.didSet(f, for: .leftHalf, window: w)
        #expect(s.step(for: .leftHalf, window: w, currentFrame: f) == 2)
        s.didSet(f, for: .leftHalf, window: w)
        #expect(s.step(for: .leftHalf, window: w, currentFrame: f) == 0)
    }

    @Test func frameWithin2ptStillRepeats() {
        var s = CycleState()
        s.didSet(f, for: .leftHalf, window: w)
        #expect(s.step(for: .leftHalf, window: w, currentFrame: f.offsetBy(dx: 1.5, dy: 0)) == 1)
    }

    @Test func movedWindowResets() {
        var s = CycleState()
        s.didSet(f, for: .leftHalf, window: w)
        #expect(s.step(for: .leftHalf, window: w, currentFrame: f.offsetBy(dx: 10, dy: 0)) == 0)
    }

    @Test func otherActionResets() {
        var s = CycleState()
        s.didSet(f, for: .leftHalf, window: w)
        #expect(s.step(for: .rightHalf, window: w, currentFrame: f) == 0)
    }

    @Test func otherWindowResets() {
        var s = CycleState()
        s.didSet(f, for: .leftHalf, window: w)
        #expect(s.step(for: .leftHalf, window: 2, currentFrame: f) == 0)
    }

    @Test func nonCyclingAlwaysZero() {
        var s = CycleState()
        #expect(s.step(for: .maximize, window: w, currentFrame: f) == 0)
        s.didSet(f, for: .maximize, window: w)
        #expect(s.step(for: .maximize, window: w, currentFrame: f) == 0)
    }
}
