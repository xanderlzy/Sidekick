import CoreGraphics

enum WindowLayout {
    static let sizeStep: CGFloat = 30
    static let minSize = CGSize(width: 200, height: 150)
    static let almostMaximizeFraction: CGFloat = 0.9

    private static let halfFractions: [CGFloat] = [1.0 / 2, 2.0 / 3, 1.0 / 3]

    /// Target frame in AX coordinates, or nil when the action isn't a pure layout
    /// (`.restore`) or can't apply (display moves with a single display).
    static func target(for action: WindowAction, window: CGRect, display: Display, displays: [Display], step: Int) -> CGRect? {
        let v = display.visible
        let s = ((step % 3) + 3) % 3
        let portrait = v.height > v.width
        switch action {
        case .leftHalf:
            return CGRect(x: v.minX, y: v.minY, width: v.width * halfFractions[s], height: v.height)
        case .rightHalf:
            let w = v.width * halfFractions[s]
            return CGRect(x: v.maxX - w, y: v.minY, width: w, height: v.height)
        case .topHalf:
            return CGRect(x: v.minX, y: v.minY, width: v.width, height: v.height * halfFractions[s])
        case .bottomHalf:
            let h = v.height * halfFractions[s]
            return CGRect(x: v.minX, y: v.maxY - h, width: v.width, height: h)
        case .topLeft:
            return CGRect(x: v.minX, y: v.minY, width: v.width / 2, height: v.height / 2)
        case .topRight:
            return CGRect(x: v.midX, y: v.minY, width: v.width / 2, height: v.height / 2)
        case .bottomLeft:
            return CGRect(x: v.minX, y: v.midY, width: v.width / 2, height: v.height / 2)
        case .bottomRight:
            return CGRect(x: v.midX, y: v.midY, width: v.width / 2, height: v.height / 2)
        case .firstThird: return slice(v, portrait: portrait, index: CGFloat([0, 1, 2][s]), of: 3, span: 1)
        case .centerThird: return slice(v, portrait: portrait, index: 1, of: 3, span: 1)
        case .lastThird: return slice(v, portrait: portrait, index: CGFloat([2, 1, 0][s]), of: 3, span: 1)
        case .firstTwoThirds: return slice(v, portrait: portrait, index: 0, of: 3, span: 2)
        case .centerTwoThirds: return slice(v, portrait: portrait, index: 0.5, of: 3, span: 2)
        case .lastTwoThirds: return slice(v, portrait: portrait, index: 1, of: 3, span: 2)
        case .maximize:
            return v
        case .almostMaximize:
            let w = v.width * almostMaximizeFraction, h = v.height * almostMaximizeFraction
            return CGRect(x: v.midX - w / 2, y: v.midY - h / 2, width: w, height: h)
        case .maximizeHeight:
            return CGRect(x: window.minX, y: v.minY, width: window.width, height: v.height)
        case .larger:
            let g = window.insetBy(dx: -sizeStep, dy: -sizeStep)
            let w = min(g.width, v.width), h = min(g.height, v.height)
            return CGRect(x: min(max(g.minX, v.minX), v.maxX - w),
                          y: min(max(g.minY, v.minY), v.maxY - h), width: w, height: h)
        case .smaller:
            let w = min(window.width, max(minSize.width, window.width - 2 * sizeStep))
            let h = min(window.height, max(minSize.height, window.height - 2 * sizeStep))
            return CGRect(x: window.midX - w / 2, y: window.midY - h / 2, width: w, height: h)
        case .center:
            return CGRect(x: v.midX - window.width / 2, y: v.midY - window.height / 2, width: window.width, height: window.height)
        case .restore:
            return nil
        case .nextDisplay, .previousDisplay:
            guard displays.count > 1 else { return nil }
            let dest = ScreenGeometry.neighbor(of: display, in: displays, offset: action == .nextDisplay ? 1 : -1)
            return mapped(window, from: v, to: dest.visible)
        }
    }

    /// `index` and `span` are in units of `of`ths along the split axis
    /// (horizontal on landscape, vertical on portrait).
    private static func slice(_ v: CGRect, portrait: Bool, index: CGFloat, of n: CGFloat, span: CGFloat) -> CGRect {
        if portrait {
            return CGRect(x: v.minX, y: v.minY + v.height * index / n, width: v.width, height: v.height * span / n)
        }
        return CGRect(x: v.minX + v.width * index / n, y: v.minY, width: v.width * span / n, height: v.height)
    }

    private static func mapped(_ w: CGRect, from src: CGRect, to dst: CGRect) -> CGRect {
        let width = min(dst.width, w.width / src.width * dst.width)
        let height = min(dst.height, w.height / src.height * dst.height)
        let x = dst.minX + (w.minX - src.minX) / src.width * dst.width
        let y = dst.minY + (w.minY - src.minY) / src.height * dst.height
        return CGRect(
            x: min(max(x, dst.minX), dst.maxX - width),
            y: min(max(y, dst.minY), dst.maxY - height),
            width: width, height: height)
    }
}
