import CoreGraphics

/// Tells a window move apart from other drags, and sizes a snapped window back
/// to its original size when the user drags it away. Pure geometry, AX coordinates.
enum DragClassifier {
    static let moveThreshold: CGFloat = 2
    static let sizeTolerance: CGFloat = 1
    /// Cursor travel after which a still window means the drag isn't moving it.
    static let travelLimit: CGFloat = 10
    /// How far a snapped window may sit from where Window Manager put it and still count as snapped.
    static let snappedTolerance: CGFloat = 2

    /// True when the window's origin moved more than 2pt while its size stayed put (±1pt).
    /// Edge resizes change the size; text selection and file drags leave the frame alone.
    static func isWindowDrag(start: CGRect, now: CGRect) -> Bool {
        let moved = abs(now.minX - start.minX) > moveThreshold || abs(now.minY - start.minY) > moveThreshold
        let sameSize = abs(now.width - start.width) <= sizeTolerance && abs(now.height - start.height) <= sizeTolerance
        return moved && sameSize
    }

    /// The original size, placed so the cursor keeps its fraction across the title bar.
    static func unsnapFrame(current: CGRect, original: CGSize, cursor: CGPoint) -> CGRect {
        let x = cursor.x - (cursor.x - current.minX) * original.width / current.width
        return CGRect(x: x, y: current.minY, width: original.width, height: original.height)
    }

    /// True once the cursor has travelled more than 10pt while the window's origin stayed within 2pt:
    /// a text selection, file drag or similar, so there's no point asking AX any further.
    static func isNonWindowDrag(start: CGRect, now: CGRect, cursorTravel: CGFloat) -> Bool {
        let still = abs(now.minX - start.minX) <= moveThreshold && abs(now.minY - start.minY) <= moveThreshold
        return cursorTravel > travelLimit && still
    }

    /// True when a window's frame at drag start is still the one Window Manager applied:
    /// same size (±2pt), origin within 2pt plus `slack` (how far the cursor had moved before the start frame was read).
    static func isStillSnapped(applied: CGRect, start: CGRect, slack: CGFloat) -> Bool {
        let originTolerance = snappedTolerance + slack
        return abs(applied.minX - start.minX) <= originTolerance && abs(applied.minY - start.minY) <= originTolerance
            && abs(applied.width - start.width) <= snappedTolerance && abs(applied.height - start.height) <= snappedTolerance
    }

    /// True when a drag event arrives with the left button already up: the mouse-up went
    /// elsewhere (Mission Control, a Space switch, a modal), so the drag is over.
    static func isStaleDrag(pressedButtons: Int) -> Bool {
        pressedButtons & 1 == 0
    }
}
