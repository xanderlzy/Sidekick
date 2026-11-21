import CoreGraphics

/// @unchecked Sendable: AnyHashable is not Sendable, but only value-type window keys are stored.
/// Tracks repeat presses of the same action on the same window so halves/thirds can cycle.
struct CycleState: @unchecked Sendable {
    static let cycling: Set<WindowAction> = [.leftHalf, .rightHalf, .topHalf, .bottomHalf, .firstThird, .lastThird]
    static let stepCount = 3
    static let tolerance: CGFloat = 2

    private struct Last {
        var action: WindowAction
        var window: AnyHashable
        var frame: CGRect
        var step: Int
    }

    private var last: Last?
    private var pending: (action: WindowAction, window: AnyHashable, step: Int)?

    /// The step to use for this press. A repeat of the same action on the same,
    /// unmoved window advances; anything else starts at 0.
    mutating func step(for action: WindowAction, window: AnyHashable, currentFrame: CGRect) -> Int {
        var result = 0
        if Self.cycling.contains(action),
           let last, last.action == action, last.window == window,
           Self.isClose(last.frame, currentFrame) {
            result = (last.step + 1) % Self.stepCount
        }
        pending = (action, window, result)
        return result
    }

    /// Records the frame that was actually applied for the step last returned.
    mutating func didSet(_ frame: CGRect, for action: WindowAction, window: AnyHashable) {
        guard Self.cycling.contains(action) else { last = nil; pending = nil; return }
        let step = (pending.flatMap { $0.action == action && $0.window == window ? $0.step : nil }) ?? 0
        last = Last(action: action, window: window, frame: frame, step: step)
        pending = nil
    }

    private static func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }
}
