import AppKit

/// A display in Accessibility coordinates (origin top-left of the primary display, y down).
struct Display: Equatable, Sendable {
    let frame: CGRect
    let visible: CGRect
}

enum ScreenGeometry {
    /// Converts between Cocoa (bottom-left origin) and AX (top-left origin). Its own inverse.
    static func flip(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func flip(_ p: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    @MainActor
    static func currentDisplays() -> [Display] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let h = primary.frame.height
        return screens.map {
            Display(frame: flip($0.frame, primaryHeight: h), visible: flip($0.visibleFrame, primaryHeight: h))
        }
    }

    static func ordered(_ displays: [Display]) -> [Display] {
        displays.sorted {
            $0.frame.minX != $1.frame.minX ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY
        }
    }

    static func display(for window: CGRect, in displays: [Display]) -> Display? {
        var best: (Display, CGFloat)?
        for d in displays {
            let i = d.frame.intersection(window)
            guard !i.isNull else { continue }
            let area = i.width * i.height
            if area > 0, area > (best?.1 ?? 0) { best = (d, area) }
        }
        if let best { return best.0 }
        let c = CGPoint(x: window.midX, y: window.midY)
        return displays.first { $0.frame.contains(c) }
    }

    static func neighbor(of d: Display, in displays: [Display], offset: Int) -> Display {
        let list = ordered(displays)
        guard !list.isEmpty else { return d }
        let i = list.firstIndex(of: d) ?? 0
        let n = list.count
        return list[((i + offset) % n + n) % n]
    }
}
