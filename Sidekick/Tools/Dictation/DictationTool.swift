import SwiftUI

/// Hold a key, speak, and polished text is pasted where you're typing. Parrot's engine, as a tool.
@MainActor
final class DictationTool: Tool {
    let id = "dictation"
    let name = "Dictation"
    let symbol = "waveform"
    let summary = "Hold Fn, speak, and clean text appears where you're typing. Runs entirely on this Mac."
    let permissions: [Permission] = [.microphone, .accessibility, .speech]
    /// The trigger is a modifier key, which the menu can't show as a shortcut.
    let menuItems: [ToolMenuItem] = []

    /// Created on first `start()` and kept afterwards, so history and models survive turning off and on.
    private(set) var env: DictationEnvironment?
    private let defaults: UserDefaults
    private let startServices: Bool
    private let storeDirectory: URL

    init(defaults: UserDefaults = .standard, startServices: Bool = NSClassFromString("XCTestCase") == nil,
         storeDirectory: URL = DictationEnvironment.defaultStoreDirectory) {
        self.defaults = defaults
        self.startServices = startServices
        self.storeDirectory = storeDirectory
    }

    private var hotkey: HotkeyKey { HotkeyKey(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .fn }

    var setupSteps: [OnboardingStep] {
        [.microphone, .accessibility, .speechModel, .appleIntelligence]
            + (hotkey == .fn ? [.globeKey] : [])
            + [.practice, .tryIt]
    }

    var pages: [ToolPage] {
        [
            ToolPage(id: "home", title: "Home") { [weak self] in
                guard let env = self?.env else { return AnyView(EmptyView()) }
                return AnyView(DictationHomeView(env: env))
            },
            ToolPage(id: "history", title: "History") { [weak self] in
                guard let env = self?.env else { return AnyView(EmptyView()) }
                return AnyView(DictationHistoryView(env: env).modelContainer(env.history.container))
            },
            ToolPage(id: "settings", title: "Settings") { [weak self] in
                guard let env = self?.env else { return AnyView(EmptyView()) }
                return AnyView(DictationSettingsView(env: env))
            },
        ]
    }

    /// Idempotent: setup steps may start the tool before the registry turns it on.
    func start() {
        let env = env ?? DictationEnvironment(storeDirectory: storeDirectory, defaults: defaults)
        self.env = env
        if startServices { env.startAll() }
    }

    func stop() {
        env?.stopAll()
    }
}
