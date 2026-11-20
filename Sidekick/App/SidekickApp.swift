import SwiftUI

@main
struct SidekickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Sidekick", systemImage: "square.on.square") {
            Button("Open Sidekick…") { AppEnvironment.shared.window.show() }
            Divider()
            Button("Check for Updates…") { AppEnvironment.shared.updater?.checkForUpdates() }
                .disabled(AppEnvironment.shared.updater == nil)
            Divider()
            Button("Quit Sidekick") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests host inside the app; skip setup there.
        guard NSClassFromString("XCTestCase") == nil else { return }
        _ = AppEnvironment.shared
    }
}
