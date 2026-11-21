import Testing
import CoreGraphics
@testable import Sidekick

struct DragClassifierTests {
    private let start = CGRect(x: 100, y: 100, width: 500, height: 400)

    @Test func moveIsWindowDrag() {
        #expect(DragClassifier.isWindowDrag(start: start, now: CGRect(x: 150, y: 120, width: 500, height: 400)))
    }

    @Test func resizeIsNotWindowDrag() {
        #expect(!DragClassifier.isWindowDrag(start: start, now: CGRect(x: 100, y: 100, width: 560, height: 400)))
        #expect(!DragClassifier.isWindowDrag(start: start, now: CGRect(x: 90, y: 100, width: 510, height: 400)))
    }

    @Test func stillWindowIsNotWindowDrag() {
        #expect(!DragClassifier.isWindowDrag(start: start, now: start))
    }

    @Test func unsnapKeepsCursorFraction() {
        let frame = DragClassifier.unsnapFrame(current: CGRect(x: 0, y: 25, width: 800, height: 900),
                                               original: CGSize(width: 400, height: 300),
                                               cursor: CGPoint(x: 400, y: 30))
        #expect(approx(frame, CGRect(x: 200, y: 25, width: 400, height: 300)))
    }
}
