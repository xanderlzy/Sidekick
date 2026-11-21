import AppKit

/// Drives edge and corner snapping while Window Manager is on.
@MainActor
protocol SnapController: AnyObject {
    func start()
    func stop()
}

/// Watches global mouse drags. When a window is dragged into a snap area it shows a preview,
/// and on release it places the window there. Dragging a snapped window away gives it back
/// its original size.
@MainActor
final class DragSnapMonitor: SnapController {
    private let mover: WindowMover
    private var monitor: Any?
    private var preview: SnapPreviewPanel?

    // Per-drag state.
    private var downPoint: CGPoint?
    /// Where the cursor was when the start frame was read; travel is measured from here, not from the click.
    private var resolvePoint: CGPoint?
    private var resolveTime: Date?
    private var resolved = false
    private var window: AXWindow?
    private var startFrame: CGRect?
    /// How far the cursor had moved when the start frame was read; the window can't have moved further.
    private var startSlack: CGFloat = 0
    private var isWindowDrag = false
    /// Set once the drag is known not to be a window move (a resize, a text selection), so we stop asking AX.
    private var ignored = false
    private var lastAction: WindowAction?
    /// The display under the cursor when `lastAction` was chosen; the drop lands there, like the preview.
    private var lastDisplay: Display?

    init(mover: WindowMover) {
        self.mover = mover
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.handle(type) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        preview?.close()
        preview = nil
        reset()
    }

    private func handle(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown: mouseDown()
        case .leftMouseDragged: dragged()
        case .leftMouseUp: mouseUp()
        default: break
        }
    }

    private func mouseDown() {
        reset()
        preview?.hide()
        // Hit-testing is deferred to the first drag event so plain clicks stay cheap.
        downPoint = Self.cursor()
    }

    private func dragged() {
        if DragClassifier.isStaleDrag(pressedButtons: NSEvent.pressedMouseButtons) {
            preview?.hide()
            reset()
            return
        }
        guard let downPoint, !ignored else { return }
        let cursor = Self.cursor()
        if !resolved {
            resolved = true
            window = AXWindow.at(downPoint)
            startFrame = window?.frame
            startSlack = max(abs(cursor.x - downPoint.x), abs(cursor.y - downPoint.y))
            resolvePoint = cursor
            resolveTime = Date()
        }
        guard let window, let startFrame else { return }

        if !isWindowDrag {
            guard let now = window.frame else { return }
            if abs(now.width - startFrame.width) > DragClassifier.sizeTolerance
                || abs(now.height - startFrame.height) > DragClassifier.sizeTolerance {
                ignored = true
                return
            }
            guard DragClassifier.isWindowDrag(start: startFrame, now: now) else {
                let origin = resolvePoint ?? downPoint
                let travel = max(abs(cursor.x - origin.x), abs(cursor.y - origin.y))
                if DragClassifier.isNonWindowDrag(start: startFrame, now: now, cursorTravel: travel,
                                                  elapsed: Date().timeIntervalSince(resolveTime ?? Date())) { ignored = true }
                return
            }
            if window.isFullScreen { ignored = true; return }
            isWindowDrag = true
            unsnapIfNeeded(window, start: startFrame, now: now, cursor: cursor)
        }
        updatePreview(frame: startFrame, cursor: cursor)
    }

    private func mouseUp() {
        if isWindowDrag, let action = lastAction, let window {
            mover.perform(action, on: window, display: lastDisplay)
        }
        preview?.hide()
        reset()
    }

    /// A window still where Window Manager snapped it gets its original size back as it's dragged away.
    private func unsnapIfNeeded(_ window: AXWindow, start: CGRect, now: CGRect, cursor: CGPoint) {
        let id = window.id
        guard let applied = mover.lastApplied(for: id), let original = mover.restore.original(for: id),
              DragClassifier.isStillSnapped(applied: applied, start: start, slack: startSlack) else { return }
        // Keep the restore memory if the app refused the new size.
        guard window.setFrame(DragClassifier.unsnapFrame(current: now, original: original.size, cursor: cursor)) else { return }
        _ = mover.restore.take(for: id)
    }

    /// `frame` only feeds window-relative layouts, which no snap area produces, so the start frame saves an AX read.
    private func updatePreview(frame: CGRect, cursor: CGPoint) {
        let displays = ScreenGeometry.currentDisplays()
        guard let display = displays.first(where: { $0.frame.contains(cursor) }) else {
            lastAction = nil
            lastDisplay = nil
            preview?.hide()
            return
        }
        let action = SnapAreas.action(at: cursor, on: display, displays: displays, previous: lastAction)
        lastAction = action
        lastDisplay = display
        guard let action,
              let target = WindowLayout.target(for: action, window: frame, display: display, displays: displays, step: 0)
        else {
            preview?.hide()
            return
        }
        if preview == nil { preview = SnapPreviewPanel() }
        preview?.show(target, on: display)
    }

    private func reset() {
        downPoint = nil
        resolvePoint = nil
        resolveTime = nil
        resolved = false
        window = nil
        startFrame = nil
        startSlack = 0
        isWindowDrag = false
        ignored = false
        lastAction = nil
        lastDisplay = nil
    }

    /// The cursor in AX coordinates.
    private static func cursor() -> CGPoint {
        ScreenGeometry.flip(NSEvent.mouseLocation, primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
    }
}
