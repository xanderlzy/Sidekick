import Testing
import CoreGraphics
@testable import Sidekick

struct PiPLayoutTests {
    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    @Test func pipKeepsAspectAndScale() {
        let f = PiPLayout.pipFrame(source: CGRect(x: 0, y: 0, width: 1000, height: 600), screen: screen)
        #expect(f.size == CGSize(width: 350, height: 210))
    }

    @Test func pipRespectsMinWidth() {
        let f = PiPLayout.pipFrame(source: CGRect(x: 0, y: 0, width: 400, height: 300), screen: screen)
        #expect(f.size == CGSize(width: 240, height: 180))
    }

    @Test func pipGoesToNearestCorner() {
        let bl = PiPLayout.pipFrame(source: CGRect(x: 100, y: 100, width: 800, height: 500), screen: screen)
        #expect(bl.origin == CGPoint(x: 16, y: 16))
        let tr = PiPLayout.pipFrame(source: CGRect(x: 1000, y: 500, width: 800, height: 500), screen: screen)
        #expect(tr.maxX == 1904)
        #expect(tr.maxY == 1064)
    }

    @Test func snapsToNearestCorner() {
        let f = PiPLayout.snapped(CGRect(x: 1500, y: 100, width: 300, height: 200), screen: screen)
        #expect(f.origin == CGPoint(x: 1604, y: 16))
        #expect(f.size == CGSize(width: 300, height: 200))
    }

    @Test func clampsIntoScreen() {
        let a = PiPLayout.clamped(CGRect(x: 1800, y: 500, width: 300, height: 200), into: screen)
        #expect(a.maxX <= 1920)
        #expect(a.size == CGSize(width: 300, height: 200))
        let b = PiPLayout.clamped(CGRect(x: 0, y: 0, width: 3000, height: 1500), into: screen)
        #expect(b.width <= 1920 && b.height <= 1080)
        #expect(abs(b.width / b.height - 2) < 0.0001)
        #expect(screen.contains(b))
    }
}
