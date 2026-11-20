import AppKit
import SwiftUI
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let pinWindow = Self("pinWindow", default: .init(.t, modifiers: [.control, .option]))
}

/// Pins the frontmost window as a floating live copy when the shortcut is pressed.
@MainActor
final class KeepOnTopTool: Tool {
    let id = "keepOnTop"
    let name = "Keep on Top"
    let symbol = "pin"
    let summary = "Float any window above the rest. Press ⌃⌥T on the window you want to keep watching."
    let permissions: [Permission] = [.screenRecording]
    let setupSteps: [OnboardingStep] = [.screenRecording]

    let pins: PinController
    private let hasPermission: () -> Bool
    private let frontmost: () -> WindowInfo?
    private let requestSetup: () -> Void
    private let beep: () -> Void
    private var handlerRegistered = false

    init(pins: PinController, hasPermission: @escaping () -> Bool = { Permissions.screenRecording },
         frontmost: @escaping () -> WindowInfo? = WindowFinder.frontmost,
         requestSetup: @escaping () -> Void, beep: @escaping () -> Void = { NSSound.beep() }) {
        self.pins = pins
        self.hasPermission = hasPermission
        self.frontmost = frontmost
        self.requestSetup = requestSetup
        self.beep = beep
    }

    var pages: [ToolPage] {
        [ToolPage(id: "main", title: name) { [pins] in AnyView(KeepOnTopPage(pins: pins)) }]
    }

    var menuItems: [ToolMenuItem] {
        var items = [ToolMenuItem(id: "pin", title: "Pin Front Window", shortcut: .pinWindow) { [weak self] in
            self?.handleShortcut()
        }]
        if !pins.pins.isEmpty {
            items.append(ToolMenuItem(id: "unpinAll", title: "Unpin All", shortcut: nil) { [pins] in pins.unpinAll() })
        }
        return items
    }

    func handleShortcut() {
        guard hasPermission() else { requestSetup(); return }
        guard let window = frontmost() else { beep(); return }
        pins.toggle(window)
    }

    func start() {
        if !handlerRegistered {
            handlerRegistered = true
            KeyboardShortcuts.onKeyUp(for: .pinWindow) { [weak self] in self?.handleShortcut() }
        }
        KeyboardShortcuts.enable(.pinWindow)
    }

    func stop() {
        KeyboardShortcuts.disable(.pinWindow)
        pins.unpinAll()
    }
}
