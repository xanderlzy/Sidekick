import CoreGraphics

/// Tells a window move apart from other drags, and sizes a snapped window back
/// to its original size when the user drags it away. Pure geometry, AX coordinates.
enum DragClassifier {
    static let moveThreshold: CGFloat = 2
    static let sizeTolerance: CGFloat = 1

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
}
