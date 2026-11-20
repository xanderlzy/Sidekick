import AppKit
import SwiftUI

/// Builds and owns the app's long-lived objects.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    /// Tools register here (Keep on Top and Dictation arrive in later tasks).
    let registry = ToolRegistry(tools: [])
    private(set) var window: MainWindowController!
    /// Nil inside unit tests, where Sparkle shouldn't run.
    let updater: Updater? = NSClassFromString("XCTestCase") == nil ? Updater() : nil

    private init() {
        window = MainWindowController { [unowned self] nav in AnyView(RootView(env: self, navigation: nav)) }
    }
}
