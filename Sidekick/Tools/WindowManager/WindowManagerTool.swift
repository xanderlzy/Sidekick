import KeyboardShortcuts
import SwiftUI

/// Keyboard-driven window placement, in the spirit of Rectangle.
@MainActor
final class WindowManagerTool: Tool {
    static let snapEnabledKey = "windowManager.snapEnabled"

    let id = "windowManager"
    let name = "Window Manager"
    let symbol = "rectangle.split.2x2"
    let summary = "Snap windows to halves, thirds and corners with shortcuts or by dragging to the screen's edges."
    let permissions: [Permission] = [.accessibility]
    let setupSteps: [OnboardingStep] = [.accessibility]
    let menuTitle: String? = "Window Manager"

    private(set) var isRunning = false
    private let defaults: UserDefaults
    private let mover: WindowMover
    private let snapping: any SnapController
    private var snapRunning = false
    private let systemEdgeTiling: @MainActor () -> Bool

    init(defaults: UserDefaults = .standard, mover: WindowMover = WindowMover(), snapping: (any SnapController)? = nil,
         systemEdgeTiling: @escaping @MainActor () -> Bool = { SystemTiling.edgeTilingEnabled() }) {
        self.defaults = defaults
        self.mover = mover
        self.snapping = snapping ?? DragSnapMonitor(mover: mover)
        self.systemEdgeTiling = systemEdgeTiling
    }

    /// Whether macOS's own drag-to-edge tiling is on, which competes with drag-to-snap.
    var systemEdgeTilingOn: Bool { systemEdgeTiling() }

    var snapEnabled: Bool {
        defaults.object(forKey: Self.snapEnabledKey) as? Bool ?? true
    }

    var pages: [ToolPage] {
        [ToolPage(id: "settings", title: "Settings") { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(WindowManagerSettingsView(tool: self))
        }]
    }

    var menuItems: [ToolMenuItem] {
        WindowAction.allCases.map { action in
            ToolMenuItem(id: "wm.\(action.rawValue)", title: action.title, shortcut: action.shortcutName,
                         action: { [mover] in mover.perform(action) },
                         inCheatSheet: [.leftHalf, .rightHalf, .topHalf, .bottomHalf].contains(action))
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        for action in WindowAction.allCases {
            KeyboardShortcuts.onKeyDown(for: action.shortcutName) { [mover] in mover.perform(action) }
        }
        if snapEnabled { startSnapping() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for action in WindowAction.allCases { KeyboardShortcuts.removeHandler(for: action.shortcutName) }
        stopSnapping()
    }

    func setSnapping(_ on: Bool) {
        defaults.set(on, forKey: Self.snapEnabledKey)
        guard isRunning else { return }
        if on { startSnapping() } else { stopSnapping() }
    }

    func accessibilityGranted() {
        guard isRunning else { return }
        stop()
        start()
    }

    private func startSnapping() {
        guard !snapRunning else { return }
        snapRunning = true
        snapping.start()
    }

    private func stopSnapping() {
        guard snapRunning else { return }
        snapRunning = false
        snapping.stop()
    }
}
