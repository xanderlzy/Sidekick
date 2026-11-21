import Foundation
import Testing
import CoreGraphics
@testable import Sidekick

@MainActor
final class FakeWindow: WindowHandle {
    let id: AnyHashable = AnyHashable(UUID())
    var current: CGRect
    var minSize: CGSize?
    var fixedSize: CGSize?
    /// Nothing applies and the write reports failure.
    var failsSet = false
    /// The position applies but the size write errors (a fixed-size window): reports failure.
    var rejectsSize = false
    /// Everything applies but the write still reports failure (a busy app that timed out).
    var reportsFailure = false
    var isFullScreen = false
    var isMinimized = false

    init(_ frame: CGRect, minSize: CGSize? = nil, fixedSize: CGSize? = nil) {
        current = frame
        self.minSize = minSize
        self.fixedSize = fixedSize
    }

    var frame: CGRect? { current }

    func setFrame(_ frame: CGRect) -> Bool {
        if failsSet { return false }
        var size = rejectsSize ? current.size : frame.size
        if let m = minSize { size = CGSize(width: max(size.width, m.width), height: max(size.height, m.height)) }
        if let f = fixedSize { size = f }
        current = CGRect(origin: frame.origin, size: size)
        return !(rejectsSize || reportsFailure)
    }
}

@MainActor
struct WindowMoverTests {
    let main = Display(frame: CGRect(x: 0, y: 0, width: 1600, height: 1000), visible: CGRect(x: 0, y: 25, width: 1600, height: 900))

    private func mover(focused: (any WindowHandle)? = nil) -> WindowMover {
        WindowMover(displays: { [main] }, focusedWindow: { focused })
    }

    @Test func displayOverrideWins() {
        let right = Display(frame: CGRect(x: 1600, y: 0, width: 1440, height: 900), visible: CGRect(x: 1600, y: 0, width: 1440, height: 900))
        let m = WindowMover(displays: { [main, right] }, focusedWindow: { nil })
        // Mostly on main, a sliver on the right display.
        let w = FakeWindow(CGRect(x: 1000, y: 100, width: 700, height: 400))
        m.perform(.leftHalf, on: w, display: right)
        #expect(approx(w.current, CGRect(x: 1600, y: 0, width: 720, height: 900)))
    }

    @Test func appliesLeftHalf() {
        let w = FakeWindow(CGRect(x: 100, y: 100, width: 500, height: 400))
        mover().perform(.leftHalf, on: w)
        #expect(approx(w.current, CGRect(x: 0, y: 25, width: 800, height: 900)))
    }

    @Test func repeatCyclesToTwoThirds() {
        let w = FakeWindow(CGRect(x: 100, y: 100, width: 500, height: 400))
        let m = mover()
        m.perform(.leftHalf, on: w)
        m.perform(.leftHalf, on: w)
        #expect(abs(w.current.width - 1066.67) < 0.01)
    }

    @Test func restoreReturnsOriginal() {
        let original = CGRect(x: 100, y: 100, width: 500, height: 400)
        let w = FakeWindow(original)
        let m = mover()
        m.perform(.maximize, on: w)
        m.perform(.leftHalf, on: w)
        m.perform(.restore, on: w)
        #expect(approx(w.current, original))
        m.perform(.restore, on: w)
        #expect(approx(w.current, original))
    }

    @Test func minSizeWindowAnchoredRight() {
        let w = FakeWindow(CGRect(x: 100, y: 100, width: 500, height: 400), minSize: CGSize(width: 1000, height: 100))
        mover().perform(.rightHalf, on: w)
        #expect(abs(w.current.maxX - 1600) < 0.01)
        #expect(abs(w.current.width - 1000) < 0.01)
    }

    @Test func fixedSizeCentered() {
        let w = FakeWindow(CGRect(x: 100, y: 100, width: 700, height: 700), fixedSize: CGSize(width: 700, height: 700))
        mover().perform(.maximize, on: w)
        #expect(approx(w.current, CGRect(x: 450, y: 125, width: 700, height: 700)))
    }

    @Test func noWindowIsNoOp() {
        mover(focused: nil).perform(.leftHalf)
    }

    @Test func focusedWindowIsUsed() {
        let w = FakeWindow(CGRect(x: 100, y: 100, width: 500, height: 400))
        mover(focused: w).perform(.leftHalf)
        #expect(approx(w.current, CGRect(x: 0, y: 25, width: 800, height: 900)))
    }

    @Test func fullScreenIsNoOp() {
        let original = CGRect(x: 100, y: 100, width: 500, height: 400)
        let w = FakeWindow(original)
        w.isFullScreen = true
        mover().perform(.leftHalf, on: w)
        #expect(w.current == original)
    }

    @Test func failedSetIsNoOp() {
        let w = FakeWindow(CGRect(x: 100, y: 100, width: 500, height: 400))
        w.failsSet = true
        let m = mover()
        m.perform(.leftHalf, on: w)
        #expect(m.lastApplied(for: w.id) == nil)
    }

    @Test func adjustKeepsLeftEdge() {
        let v = main.visible
        let r = WindowLayout.adjust(target: CGRect(x: 0, y: 25, width: 800, height: 900), actual: CGSize(width: 1000, height: 900), visible: v)
        #expect(approx(r, CGRect(x: 0, y: 25, width: 1000, height: 900)))
    }

    @Test func adjustShiftsInsideVisible() {
        let v = main.visible
        let r = WindowLayout.adjust(target: CGRect(x: 1000, y: 25, width: 600, height: 300), actual: CGSize(width: 600, height: 300), visible: v)
        #expect(approx(r, CGRect(x: 1000, y: 25, width: 600, height: 300)))
    }

    @Test func rejectedSizeStillAnchored() {
        let w = FakeWindow(CGRect(x: 100, y: 100, width: 700, height: 700))
        w.rejectsSize = true
        let m = mover()
        m.perform(.maximize, on: w)
        let centered = CGRect(x: 450, y: 125, width: 700, height: 700)
        #expect(approx(w.current, centered))
        #expect(m.lastApplied(for: w.id).map { approx($0, centered) } == true)
    }

    @Test func reportedFailureStillCycles() {
        let w = FakeWindow(CGRect(x: 100, y: 100, width: 500, height: 400))
        w.reportsFailure = true
        let m = mover()
        m.perform(.leftHalf, on: w)
        #expect(approx(w.current, CGRect(x: 0, y: 25, width: 800, height: 900)))
        m.perform(.leftHalf, on: w)
        #expect(abs(w.current.width - 1066.67) < 0.01)
    }

    @Test func restoreKeepsMemoryWhenWindowDoesNotChange() {
        let original = CGRect(x: 100, y: 100, width: 500, height: 400)
        let w = FakeWindow(original)
        let m = mover()
        m.perform(.maximize, on: w)
        w.failsSet = true
        m.perform(.restore, on: w)
        #expect(approx(w.current, main.visible))
        #expect(m.restore.original(for: w.id) == original)
        w.failsSet = false
        m.perform(.restore, on: w)
        #expect(approx(w.current, original))
        #expect(m.restore.original(for: w.id) == nil)
    }

    @Test func restoreWithReportedFailureStillRestores() {
        let original = CGRect(x: 100, y: 100, width: 500, height: 400)
        let w = FakeWindow(original)
        let m = mover()
        m.perform(.maximize, on: w)
        w.reportsFailure = true
        m.perform(.restore, on: w)
        #expect(approx(w.current, original))
        #expect(m.restore.original(for: w.id) == nil)
        #expect(m.lastApplied(for: w.id).map { approx($0, original) } == true)
    }

    @Test func alreadyAtTargetStillCycles() {
        let w = FakeWindow(CGRect(x: 0, y: 25, width: 800, height: 900))
        w.reportsFailure = true
        let m = mover()
        m.perform(.leftHalf, on: w)
        m.perform(.leftHalf, on: w)
        #expect(abs(w.current.width - 1066.67) < 0.01)
    }
}
