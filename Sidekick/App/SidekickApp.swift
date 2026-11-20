import KeyboardShortcuts
import SwiftUI

@main
struct SidekickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Sidekick", systemImage: "square.on.square") {
            MenuContent(env: AppEnvironment.shared)
        }
    }
}

/// The menu: open, one section per enabled tool, then app commands.
private struct MenuContent: View {
    let env: AppEnvironment

    var body: some View {
        Group {
            Button("Open Sidekick…") { env.window.show() }
            ForEach(env.registry.enabled, id: \.id) { tool in
                if !tool.menuItems.isEmpty {
                    Divider()
                    ForEach(tool.menuItems) { item in
                        if let shortcut = item.shortcut {
                            Button(item.title, action: item.action).globalKeyboardShortcut(shortcut)
                        } else {
                            Button(item.title, action: item.action)
                        }
                    }
                }
            }
            Divider()
            Button("Check for Updates…") { env.updater?.checkForUpdates() }
                .disabled(env.updater == nil)
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
        AppEnvironment.shared.registry.startEnabled()
        // Sidekick has no Dock icon, so first-run setup must open itself.
        if Self.shouldShowWindowAtLaunch() { AppEnvironment.shared.window.show() }
    }

    /// Opening Sidekick while it's already running (Finder, Launchpad) brings its window up.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppEnvironment.shared.window.show()
        return false
    }

    static func shouldShowWindowAtLaunch(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: "onboardingComplete")
    }
}
