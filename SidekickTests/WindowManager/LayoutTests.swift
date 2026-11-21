import Testing
import CoreGraphics
@testable import Sidekick

struct LayoutTests {
    let main = Display(frame: CGRect(x: 0, y: 0, width: 1600, height: 1000), visible: CGRect(x: 0, y: 25, width: 1600, height: 900))
    let portrait = Display(frame: CGRect(x: 1600, y: 0, width: 1000, height: 1600), visible: CGRect(x: 1600, y: 0, width: 1000, height: 1600))
    let win = CGRect(x: 100, y: 100, width: 400, height: 300)

    private func t(_ a: WindowAction, _ step: Int = 0, window: CGRect? = nil, on d: Display? = nil, displays: [Display]? = nil) -> CGRect? {
        let d = d ?? main
        return Layout.target(for: a, window: window ?? win, display: d, displays: displays ?? [main, portrait], step: step)
    }

    @Test func leftHalf() {
        #expect(t(.leftHalf) == CGRect(x: 0, y: 25, width: 800, height: 900))
    }

    @Test func halfCycleSteps() {
        #expect(approx(t(.rightHalf, 1)!, CGRect(x: 533.33, y: 25, width: 1066.67, height: 900)))
        #expect(approx(t(.rightHalf, 2)!, CGRect(x: 1066.67, y: 25, width: 533.33, height: 900)))
        #expect(approx(t(.rightHalf, 3)!, CGRect(x: 800, y: 25, width: 800, height: 900)))
        #expect(approx(t(.topHalf, 1)!, CGRect(x: 0, y: 25, width: 1600, height: 600)))
    }

    @Test func cornersQuarter() {
        #expect(t(.bottomRight) == CGRect(x: 800, y: 475, width: 800, height: 450))
        #expect(t(.topLeft) == CGRect(x: 0, y: 25, width: 800, height: 450))
    }

    @Test func thirdsLandscape() {
        #expect(approx(t(.firstThird, 0)!, CGRect(x: 0, y: 25, width: 533.33, height: 900)))
        #expect(approx(t(.firstThird, 1)!, CGRect(x: 533.33, y: 25, width: 533.33, height: 900)))
        #expect(approx(t(.firstThird, 2)!, CGRect(x: 1066.67, y: 25, width: 533.33, height: 900)))
        #expect(abs(t(.lastThird, 1)!.minX - 533.33) < 0.01)
        #expect(abs(t(.lastThird, 0)!.minX - 1066.67) < 0.01)
        for s in 0..<3 { #expect(abs(t(.centerThird, s)!.minX - 533.33) < 0.01) }
    }

    @Test func thirdsPortrait() {
        #expect(approx(t(.firstThird, on: portrait)!, CGRect(x: 1600, y: 0, width: 1000, height: 533.33)))
        #expect(approx(t(.lastThird, on: portrait)!, CGRect(x: 1600, y: 1066.67, width: 1000, height: 533.33)))
    }

    @Test func twoThirds() {
        #expect(approx(t(.firstTwoThirds)!, CGRect(x: 0, y: 25, width: 1066.67, height: 900)))
        #expect(approx(t(.centerTwoThirds)!, CGRect(x: 266.67, y: 25, width: 1066.67, height: 900)))
        #expect(approx(t(.lastTwoThirds)!, CGRect(x: 533.33, y: 25, width: 1066.67, height: 900)))
    }

    @Test func maximizeVariants() {
        #expect(t(.maximize) == main.visible)
        #expect(approx(t(.almostMaximize)!, CGRect(x: 80, y: 70, width: 1440, height: 810)))
        #expect(t(.maximizeHeight, window: CGRect(x: 100, y: 300, width: 500, height: 200)) == CGRect(x: 100, y: 25, width: 500, height: 900))
    }

    @Test func largerSmaller() {
        let w = CGRect(x: 400, y: 300, width: 600, height: 400)
        #expect(t(.larger, window: w) == CGRect(x: 370, y: 270, width: 660, height: 460))
        #expect(t(.smaller, window: w) == CGRect(x: 430, y: 330, width: 540, height: 340))
        let flush = main.visible
        #expect(main.visible.contains(t(.larger, window: flush)!))
        let small = CGRect(x: 300, y: 300, width: 200, height: 150)
        #expect(t(.smaller, window: small) == small)
    }

    @Test func centerKeepsSize() {
        #expect(t(.center, window: CGRect(x: 0, y: 25, width: 400, height: 300)) == CGRect(x: 600, y: 325, width: 400, height: 300))
    }

    @Test func nextDisplayProportional() {
        let left = CGRect(x: 0, y: 25, width: 800, height: 900)
        #expect(approx(t(.nextDisplay, window: left)!, CGRect(x: 1600, y: 0, width: 500, height: 1600)))
        let fromPortrait = t(.nextDisplay, window: CGRect(x: 1700, y: 100, width: 300, height: 300), on: portrait)!
        #expect(main.visible.contains(fromPortrait))
        #expect(t(.previousDisplay, window: left) != nil)
        #expect(t(.nextDisplay, window: left, displays: [main]) == nil)
    }

    @Test func layoutOnDisplayLeftOfMain() {
        let r = CGRect(x: -1440, y: 100, width: 1440, height: 900)
        #expect(t(.leftHalf, on: Display(frame: r, visible: r)) == CGRect(x: -1440, y: 100, width: 720, height: 900))
    }

    @Test func layoutOnDisplayAboveMain() {
        let r = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        #expect(t(.bottomHalf, on: Display(frame: r, visible: r)) == CGRect(x: 0, y: -540, width: 1920, height: 540))
    }

    @Test func restoreIsNil() {
        #expect(t(.restore) == nil)
    }
}
