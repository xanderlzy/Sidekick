import CoreGraphics

enum PiPLayout {
    static func pipFrame(source: CGRect, screen: CGRect, scale: CGFloat = 0.35,
                         minWidth: CGFloat = 240, margin: CGFloat = 16) -> CGRect {
        let width = max(source.width * scale, minWidth)
        let height = source.width > 0 ? width * source.height / source.width : width
        let size = CGSize(width: width, height: height)
        let origin = cornerOrigin(size: size, nearestTo: CGPoint(x: source.midX, y: source.midY),
                                  screen: screen, margin: margin)
        return CGRect(origin: origin, size: size)
    }

    static func snapped(_ frame: CGRect, screen: CGRect, margin: CGFloat = 16) -> CGRect {
        CGRect(origin: cornerOrigin(size: frame.size, nearestTo: CGPoint(x: frame.midX, y: frame.midY),
                                    screen: screen, margin: margin),
               size: frame.size)
    }

    static func clamped(_ frame: CGRect, into screen: CGRect) -> CGRect {
        var size = frame.size
        if size.width > screen.width || size.height > screen.height {
            let k = min(screen.width / size.width, screen.height / size.height)
            size = CGSize(width: size.width * k, height: size.height * k)
        }
        let x = min(max(frame.minX, screen.minX), screen.maxX - size.width)
        let y = min(max(frame.minY, screen.minY), screen.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private static func cornerOrigin(size: CGSize, nearestTo p: CGPoint, screen: CGRect, margin: CGFloat) -> CGPoint {
        let x = p.x < screen.midX ? screen.minX + margin : screen.maxX - margin - size.width
        let y = p.y < screen.midY ? screen.minY + margin : screen.maxY - margin - size.height
        return CGPoint(x: x, y: y)
    }
}
