import CoreGraphics

/// Maps a cursor position during a window drag to a snap action. Pure geometry, AX coordinates.
enum SnapAreas {
    static let edgeMargin: CGFloat = 5
    static let cornerSize: CGFloat = 20
    static let shortEdgeSize: CGFloat = 145

    static func action(at cursor: CGPoint, on display: Display, displays: [Display], previous: WindowAction?) -> WindowAction? {
        let f = display.frame
        let others = displays.filter { $0 != display }
        func open(_ probe: CGPoint) -> Bool { !others.contains { $0.frame.contains(probe) } }

        let atLeft = cursor.x - f.minX <= edgeMargin && open(CGPoint(x: f.minX - 1, y: cursor.y))
        let atRight = f.maxX - cursor.x <= edgeMargin && open(CGPoint(x: f.maxX + 1, y: cursor.y))
        let atTop = cursor.y - f.minY <= edgeMargin && open(CGPoint(x: cursor.x, y: f.minY - 1))
        let atBottom = f.maxY - cursor.y <= edgeMargin && open(CGPoint(x: cursor.x, y: f.maxY + 1))

        let nearTop = cursor.y - f.minY <= cornerSize
        let nearBottom = f.maxY - cursor.y <= cornerSize
        let nearLeft = cursor.x - f.minX <= cornerSize
        let nearRight = f.maxX - cursor.x <= cornerSize

        // Corners first.
        if (atLeft && nearTop) || (atTop && nearLeft) { return .topLeft }
        if (atRight && nearTop) || (atTop && nearRight) { return .topRight }
        if (atLeft && nearBottom) || (atBottom && nearLeft) { return .bottomLeft }
        if (atRight && nearBottom) || (atBottom && nearRight) { return .bottomRight }

        // Left/right edges, with short-edge halves.
        if atLeft || atRight {
            if cursor.y - f.minY <= shortEdgeSize { return .topHalf }
            if f.maxY - cursor.y <= shortEdgeSize { return .bottomHalf }
            return atLeft ? .leftHalf : .rightHalf
        }
        if atTop { return .maximize }
        if atBottom {
            let third = f.width / 3
            if cursor.x < f.minX + third { return .firstThird }
            if cursor.x >= f.minX + 2 * third { return .lastThird }
            switch previous {
            case .firstThird, .firstTwoThirds: return .firstTwoThirds
            case .lastThird, .lastTwoThirds: return .lastTwoThirds
            default: return .centerThird
            }
        }
        return nil
    }
}
