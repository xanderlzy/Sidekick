import AppKit
import SwiftUI

/// Builds and owns the app's long-lived objects.
@MainActor @Observable
final class AppEnvironment {
    static let shared = AppEnvironment()

    /// Tools register here (Keep on Top and Dictation arrive in later tasks).
    let registry = ToolRegistry(tools: [])
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
        window = MainWindowController { [unowned self] nav in AnyView(RootView(env: self, navigation: nav)) }
    }
}
