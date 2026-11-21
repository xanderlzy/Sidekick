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

    @Test func stillWindowAfterCursorTravelIsNonWindowDrag() {
        #expect(DragClassifier.isNonWindowDrag(start: start, now: start, cursorTravel: 11))
        #expect(DragClassifier.isNonWindowDrag(start: start, now: CGRect(x: 102, y: 101, width: 500, height: 400), cursorTravel: 30))
    }

    @Test func shortTravelIsNotYetNonWindowDrag() {
        #expect(!DragClassifier.isNonWindowDrag(start: start, now: start, cursorTravel: 10))
    }

    @Test func movedWindowIsNotNonWindowDrag() {
        #expect(!DragClassifier.isNonWindowDrag(start: start, now: CGRect(x: 150, y: 120, width: 500, height: 400), cursorTravel: 60))
    }

    @Test func stillSnappedMatches() {
        let applied = CGRect(x: 0, y: 25, width: 800, height: 900)
        #expect(DragClassifier.isStillSnapped(applied: applied, start: CGRect(x: 4, y: 26, width: 801, height: 900), slack: 3))
    }

    @Test func stillSnappedRejectsSizeMismatch() {
        let applied = CGRect(x: 0, y: 25, width: 800, height: 900)
        #expect(!DragClassifier.isStillSnapped(applied: applied, start: CGRect(x: 0, y: 25, width: 805, height: 900), slack: 10))
    }

    @Test func stillSnappedRejectsOriginBeyondSlack() {
        let applied = CGRect(x: 0, y: 25, width: 800, height: 900)
        #expect(!DragClassifier.isStillSnapped(applied: applied, start: CGRect(x: 6, y: 25, width: 800, height: 900), slack: 3))
    }

    @Test func dragWithoutLeftButtonIsStale() {
        #expect(DragClassifier.isStaleDrag(pressedButtons: 0))
        #expect(DragClassifier.isStaleDrag(pressedButtons: 2))
        #expect(!DragClassifier.isStaleDrag(pressedButtons: 1))
        #expect(!DragClassifier.isStaleDrag(pressedButtons: 3))
    }
}
