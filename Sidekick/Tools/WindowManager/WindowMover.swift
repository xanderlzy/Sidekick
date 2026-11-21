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
            guard let frame = restore.take(for: id) else { return }
            if window.setFrame(frame) { applied[id] = window.frame ?? frame }
            cycle.didSet(frame, for: action, window: id)
            return
        }

        let step = cycle.step(for: action, window: id, currentFrame: current)
        guard let target = WindowLayout.target(for: action, window: current, display: display, displays: all, step: step) else { return }
        restore.rememberIfNeeded(current, for: id)
        guard window.setFrame(target) else { return }

        var final = window.frame ?? target
        if abs(final.width - target.width) > Self.sizeTolerance || abs(final.height - target.height) > Self.sizeTolerance {
            let destination = ScreenGeometry.display(for: target, in: all) ?? display
            let adjusted = WindowLayout.adjust(target: target, actual: final.size, visible: destination.visible)
            if window.setFrame(adjusted) { final = window.frame ?? adjusted }
        }
        applied[id] = final
        cycle.didSet(final, for: action, window: id)
    }
}
