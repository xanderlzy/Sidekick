import SwiftUI

/// Per-app volume from the menu bar. Off means off: no status item, no taps, no listeners.
@MainActor
final class VolumeMixerTool: Tool {
    let id = "volumeMixer"
    let name = "Volume Mixer"
    let symbol = "speaker.wave.2"
    let summary = "Set each app's volume from the menu bar. Sidekick remembers it for next time."
    let permissions: [Permission] = [.systemAudio]
    let setupSteps: [OnboardingStep] = [.systemAudio]
    let menuItems: [ToolMenuItem] = []

    private(set) var isRunning = false
    let store: MixerSettingsStore
    let controller: TapController
    private let systemVolume: SystemVolume
    private let menuBar: any MixerMenuBar

    init(defaults: UserDefaults = .standard,
         system: (any AudioSystem)? = nil,
         permission: TapController.PermissionCheck? = nil,
         menuBar: ((TapController, SystemVolume) -> any MixerMenuBar)? = nil) {
        let store = MixerSettingsStore(defaults: defaults)
        let system = system ?? CoreAudioSystem()
        let controller = if let permission {
            TapController(system: system, store: store, permission: permission)
        } else {
            TapController(system: system, store: store)
        }
        let systemVolume = SystemVolume()
        self.store = store
        self.controller = controller
        self.systemVolume = systemVolume
        self.menuBar = menuBar?(controller, systemVolume) ?? MixerStatusItem(
            controller: controller, systemVolume: systemVolume,
            openSettings: { AppEnvironment.shared.window.show(.page(tool: "volumeMixer", page: "settings")) })
    }

    var pages: [ToolPage] {
        [ToolPage(id: "settings", title: "Settings") { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(VolumeMixerSettingsView(store: store, controller: controller))
        }]
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        controller.start()
        systemVolume.start()
        menuBar.install()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        menuBar.remove()
        systemVolume.stop()
        controller.stop()
    }
}
