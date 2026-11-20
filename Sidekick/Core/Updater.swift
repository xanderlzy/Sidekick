import AppKit
import Sparkle

/// Sparkle auto-updates: checks daily in the background and on demand from the menu or Settings.
@MainActor
final class Updater {
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                          userDriverDelegate: nil)

    var canCheck: Bool { controller.updater.canCheckForUpdates }

    func checkForUpdates() {
        NSApp.activate()   // Sidekick is a menu bar app; bring the update window forward.
        controller.checkForUpdates(nil)
    }
}
