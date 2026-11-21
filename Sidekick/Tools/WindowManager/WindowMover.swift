import CoreGraphics

/// Applies a `WindowAction` to a window: cycling, restore memory and
/// anchoring of windows that resist the requested size.
@MainActor
final class WindowMover {
    private let displays: @MainActor () -> [Display]
    private let focusedWindow: @MainActor () -> (any WindowHandle)?
    private var cycle = CycleState()
    var restore = RestoreStore()
    private var applied: [AnyHashable: CGRect] = [:]

    static let sizeTolerance: CGFloat = 2

    init(
        displays: @escaping @MainActor () -> [Display] = { ScreenGeometry.currentDisplays() },
        focusedWindow: @escaping @MainActor () -> (any WindowHandle)? = { AXWindow.focused() }
    ) {
        self.displays = displays
        self.focusedWindow = focusedWindow
    }

    func lastApplied(for window: AnyHashable) -> CGRect? { applied[window] }

    func perform(_ action: WindowAction) {
        guard let window = focusedWindow() else { return }
        perform(action, on: window)
    }

    /// `display` overrides the display the window is judged to be on; drag-to-snap passes
    /// the display under the cursor so the drop matches the preview.
    func perform(_ action: WindowAction, on window: any WindowHandle, display override: Display? = nil) {
        guard !window.isFullScreen, !window.isMinimized, let current = window.frame else { return }
        let all = displays()
        guard let display = override ?? ScreenGeometry.display(for: current, in: all) else { return }
        let id = window.id

        if action == .restore {
            guard let frame = restore.original(for: id),
                  let final = apply(frame, to: window, from: current) else { return }
            // Forget the original only once the window has really moved back.
            _ = restore.take(for: id)
            applied[id] = final
            cycle.didSet(final, for: action, window: id)
            return
        }

        let step = cycle.step(for: action, window: id, currentFrame: current)
        guard let target = WindowLayout.target(for: action, window: current, display: display, displays: all, step: step) else { return }
        restore.rememberIfNeeded(current, for: id)
        guard var final = apply(target, to: window, from: current) else { return }

        if abs(final.width - target.width) > Self.sizeTolerance || abs(final.height - target.height) > Self.sizeTolerance {
            let destination = ScreenGeometry.display(for: target, in: all) ?? display
            let adjusted = WindowLayout.adjust(target: target, actual: final.size, visible: destination.visible)
            if let anchored = apply(adjusted, to: window, from: final) { final = anchored }
        }
        applied[id] = final
        cycle.didSet(final, for: action, window: id)
    }

    /// Sets `target` as a best effort and returns the frame the window actually has afterwards,
    /// or nil when it can't be read or nothing happened. AX writes report failure when any part
    /// fails (a fixed-size window rejects the size but still moves; a busy app times out but
    /// still resizes), so the read-back, not the return value, decides.
    private func apply(_ target: CGRect, to window: any WindowHandle, from before: CGRect) -> CGRect? {
        window.setFrame(target)
        guard let after = window.frame else { return nil }
        return Self.isClose(after, before) && !Self.isClose(after, target) ? nil : after
    }

    private static func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= sizeTolerance && abs(a.minY - b.minY) <= sizeTolerance
            && abs(a.width - b.width) <= sizeTolerance && abs(a.height - b.height) <= sizeTolerance
    }
}
