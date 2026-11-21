import Testing
import CoreGraphics
@testable import Sidekick

struct ScreenGeometryTests {
    let main = Display(frame: CGRect(x: 0, y: 0, width: 1600, height: 1000), visible: CGRect(x: 0, y: 25, width: 1600, height: 900))
    let portrait = Display(frame: CGRect(x: 1600, y: 0, width: 1000, height: 1600), visible: CGRect(x: 1600, y: 0, width: 1000, height: 1600))

    @Test func flipRoundTrips() {
        let r = CGRect(x: 10, y: 20, width: 300, height: 400)
        #expect(ScreenGeometry.flip(ScreenGeometry.flip(r, primaryHeight: 1000), primaryHeight: 1000) == r)
        #expect(ScreenGeometry.flip(CGRect(x: 0, y: 0, width: 100, height: 25), primaryHeight: 1000) == CGRect(x: 0, y: 975, width: 100, height: 25))
        #expect(ScreenGeometry.flip(CGPoint(x: 5, y: 100), primaryHeight: 1000) == CGPoint(x: 5, y: 900))
    }

    @Test func displayForWindowPicksLargestOverlap() {
        // 400 wide: 160pt (40%) on main, 240pt (60%) on portrait.
        let w = CGRect(x: 1440, y: 100, width: 400, height: 300)
        #expect(ScreenGeometry.display(for: w, in: [main, portrait]) == portrait)
    }

    @Test func displayForOffscreenWindowIsNil() {
        #expect(ScreenGeometry.display(for: CGRect(x: 5000, y: 5000, width: 100, height: 100), in: [main, portrait]) == nil)
    }

    @Test func orderedLeftToRight() {
        #expect(ScreenGeometry.ordered([portrait, main]) == [main, portrait])
        let above = Display(frame: CGRect(x: 0, y: -1080, width: 1600, height: 1080), visible: CGRect(x: 0, y: -1080, width: 1600, height: 1080))
        #expect(ScreenGeometry.ordered([main, above]) == [above, main])
    }

    @Test func neighborWraps() {
        #expect(ScreenGeometry.neighbor(of: portrait, in: [portrait, main], offset: 1) == main)
        #expect(ScreenGeometry.neighbor(of: main, in: [portrait, main], offset: -1) == portrait)
    }
}
