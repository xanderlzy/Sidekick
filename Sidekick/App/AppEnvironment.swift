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

    /// The setup sheet that's showing, if any.
    let setup: SetupCoordinator

    /// Turns a tool on, first showing its setup sheet if it needs steps the Mac hasn't satisfied yet.
    func requestSetup(toolID: String) { setup.request(toolID: toolID) }

    private convenience init() {
        self.init(tools: [DictationTool(importer: .live())])
    }

    /// Tests build their own environment around sandboxed tools and defaults.
    init(tools: [any Tool], defaults: UserDefaults = .standard) {
        registry = ToolRegistry(tools: tools, defaults: defaults)
        setup = SetupCoordinator(registry: registry, defaults: defaults)
        window = MainWindowController { [unowned self] nav in AnyView(RootView(env: self, navigation: nav)) }
        setup.showWindow = { [unowned self] in window.show() }
        // Closing the window mid-sheet abandons that setup.
        window.onClose = { [unowned self] in setup.cancel() }
    }
}
