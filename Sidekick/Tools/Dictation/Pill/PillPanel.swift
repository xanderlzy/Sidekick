import AppKit
import SwiftUI

/// A borderless, click-through panel at the bottom center of the active screen that hosts the pill.
final class PillPanel: NSPanel {
    static let size = NSSize(width: 360, height: 84)

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Bottom center of the screen under the mouse, just above the Dock.
    func reposition() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: visible.midX - Self.size.width / 2, y: visible.minY + 10))
    }
}

/// Shows and hides the panel as the controller's pill state changes.
@MainActor
final class PillPresenter {
    private let panel = PillPanel()
    private let controller: DictationController
    private var lastState: PillState = .hidden
    private var hideWork: DispatchWorkItem?
    private var closed = false

    init(controller: DictationController) {
        self.controller = controller
        let host = NSHostingView(rootView: PillHost(controller: controller))
        host.frame = NSRect(origin: .zero, size: PillPanel.size)
        panel.contentView = host
        observe()
    }

    /// Hides the panel for good and stops following the controller.
    func close() {
        closed = true
        hideWork?.cancel()
        panel.orderOut(nil)
    }

    private func observe() {
        guard !closed else { return }
        withObservationTracking {
            _ = controller.pill
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    private func update() {
        guard !closed else { return }
        let state = controller.pill
        defer { lastState = state }
        if state == .hidden {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.controller.pill == .hidden else { return }
                self.panel.orderOut(nil)
            }
            hideWork?.cancel(); hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        } else {
            hideWork?.cancel()
            if lastState == .hidden { panel.reposition() }
            panel.orderFrontRegardless()
        }
    }
}

private struct PillHost: View {
    let controller: DictationController
    var body: some View { PillView(state: controller.pill, level: controller.level) }
}
