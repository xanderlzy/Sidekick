import AppKit
import SwiftUI

/// Builds and owns the app's long-lived objects.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    private(set) var window: MainWindowController!
    /// Nil inside unit tests, where Sparkle shouldn't run.
    let updater: Updater? = NSClassFromString("XCTestCase") == nil ? Updater() : nil

    private init() {
        window = MainWindowController { [unowned self] nav in AnyView(RootView(env: self, navigation: nav)) }
    }
}
