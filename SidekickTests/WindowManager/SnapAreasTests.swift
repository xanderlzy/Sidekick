import Testing
import CoreGraphics
@testable import Sidekick

struct SnapAreasTests {
    let main = Display(frame: CGRect(x: 0, y: 0, width: 1600, height: 1000), visible: CGRect(x: 0, y: 25, width: 1600, height: 900))
    let left = Display(frame: CGRect(x: -1440, y: 0, width: 1440, height: 900), visible: CGRect(x: -1440, y: 0, width: 1440, height: 900))

    private func a(_ x: CGFloat, _ y: CGFloat, previous: WindowAction? = nil, displays: [Display]? = nil) -> WindowAction? {
        SnapAreas.action(at: CGPoint(x: x, y: y), on: main, displays: displays ?? [main], previous: previous)
    }

    @Test func leftEdge() { #expect(a(2, 500) == .leftHalf) }
    @Test func rightEdge() { #expect(a(1598, 500) == .rightHalf) }
    @Test func topEdge() { #expect(a(800, 1) == .maximize) }
    @Test func corners() {
        #expect(a(1, 1) == .topLeft)
        #expect(a(1599, 999) == .bottomRight)
    }
    @Test func shortEdgeHalves() {
        #expect(a(1, 100) == .topHalf)
        #expect(a(1, 900) == .bottomHalf)
    }
    @Test func bottomThirds() {
        #expect(a(200, 999) == .firstThird)
        #expect(a(800, 999) == .centerThird)
        #expect(a(1400, 999) == .lastThird)
    }
    @Test func bottomTwoThirdsGesture() {
        #expect(a(800, 999, previous: .firstThird) == .firstTwoThirds)
        #expect(a(800, 999, previous: .lastThird) == .lastTwoThirds)
        #expect(a(800, 999, previous: .firstTwoThirds) == .firstTwoThirds)
    }
    @Test func interiorIsNil() { #expect(a(800, 500) == nil) }
    @Test func sharedEdgeDoesNotSnap() {
        #expect(a(2, 500, displays: [main, left]) == nil)
        #expect(a(1598, 500, displays: [main, left]) == .rightHalf)
    }
}
