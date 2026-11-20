import AppKit
import SwiftUI

/// Builds and owns the app's long-lived objects.
@MainActor @Observable
final class AppEnvironment {
    static let shared = AppEnvironment()

    /// Tools register here, in Home's order.
    let registry: ToolRegistry
    @ObservationIgnored private(set) var window: MainWindowController!
    /// Nil inside unit tests, where Sparkle shouldn't run.
    @ObservationIgnored let updater: Updater? = NSClassFromString("XCTestCase") == nil ? Updater() : nil

    /// ID of the tool whose setup sheet is showing.
    var pendingSetup: String?

    /// Turns a tool on, first showing its setup sheet if it needs steps the Mac hasn't satisfied yet.
    func requestSetup(toolID: String) {
        guard let tool = registry.tools.first(where: { $0.id == toolID }) else { return }
        if OnboardingFlow.setupSteps(for: tool, satisfied: OnboardingFlow.isSatisfied).isEmpty {
            registry.setEnabled(toolID, true)
        } else {
            pendingSetup = toolID
            window.show()
        }
    }

    private init() {
        // Each mirror unpins itself when its source goes away; weak so the controller isn't kept alive by its panels.
        weak var weakPins: PinController?
        let pins = PinController { w in MirrorPanel(window: w, onClose: { weakPins?.unpin(w.id) }) }
        weakPins = pins
        registry = ToolRegistry(tools: [
            KeepOnTopTool(pins: pins, requestSetup: { AppEnvironment.shared.requestSetup(toolID: "keepOnTop") }),
            DictationTool(),
        ])
        window = MainWindowController { [unowned self] nav in AnyView(RootView(env: self, navigation: nav)) }
    }
}
