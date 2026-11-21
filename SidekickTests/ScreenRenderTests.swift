import AppKit
import SwiftUI
import Testing
@testable import Sidekick

/// Renders the settings window's screens to PNGs for visual review. Off by default; run with
/// `TEST_RUNNER_SIDEKICK_RENDER_SCREENS=1 scripts/test.sh ScreenRenderTests`
/// (xcodebuild strips the `TEST_RUNNER_` prefix). Output: `.superpowers/screens/`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SIDEKICK_RENDER_SCREENS"] == "1"))
struct ScreenRenderTests {
    private static let size = NSSize(width: 800, height: 560)
    private static let outDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: ".superpowers/screens", directoryHint: .isDirectory)

    private let defaults: UserDefaults
    private let dictation: DictationTool
    private let env: AppEnvironment

    init() {
        let suite = "ScreenRenderTests-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        let store = FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        dictation = DictationTool(defaults: defaults, startServices: false, storeDirectory: store)
        dictation.start()
        env = AppEnvironment(tools: [dictation, WindowManagerTool(defaults: defaults, systemEdgeTiling: { true })], defaults: defaults)
        env.registry.setEnabled("windowManager", true)
    }

    @Test func renderScreens() async throws {
        try FileManager.default.createDirectory(at: Self.outDir, withIntermediateDirectories: true)
        let manyEnv = AppEnvironment(tools: [dictation, SampleTool(id: "a", name: "Clipboard", symbol: "doc.on.clipboard",
                                                                   permissions: [.accessibility]),
                                             SampleTool(id: "b", name: "Timer", symbol: "timer", permissions: [])],
                                     defaults: defaults)
        let screens: [(String, AnyView)] = [
            ("home", window(env, .home)),
            ("home-many", window(manyEnv, .home)),
            ("general", window(env, .general)),
            ("dictation-home", window(env, .page(tool: "dictation", page: "home"))),
            ("dictation-history", window(env, .page(tool: "dictation", page: "history"))),
            ("dictation-settings", window(env, .page(tool: "dictation", page: "settings"))),
            ("window-manager-settings", window(env, .page(tool: "windowManager", page: "settings"))),
            ("onboarding-choose", AnyView(OnboardingView(env: env, steps: [.chooseTools, .finish], done: {}))),
            ("onboarding-welcome", AnyView(OnboardingView(env: env, steps: [.welcome, .chooseTools, .finish], done: {}))),
        ]
        for (name, view) in screens {
            for dark in [false, true] {
                try await render(view, to: "\(name)-\(dark ? "dark" : "light").png", dark: dark)
            }
        }
    }

    private func window(_ env: AppEnvironment, _ route: Route) -> AnyView {
        let nav = AppNavigation()
        nav.route = route
        return AnyView(MainWindow(env: env, navigation: nav))
    }

    private func render(_ view: AnyView, to file: String, dark: Bool) async throws {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        w.contentView = host
        w.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        w.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(900))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        w.orderOut(nil)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: Self.outDir.appending(path: file))
    }
}

@MainActor
private final class SampleTool: Tool {
    let id: String
    let name: String
    let symbol: String
    let summary = "A short sample summary that runs to two lines in a card."
    let permissions: [Permission]
    let setupSteps: [OnboardingStep] = []
    let pages: [ToolPage] = []
    let menuItems: [ToolMenuItem] = []
    init(id: String, name: String, symbol: String, permissions: [Permission]) {
        self.id = id; self.name = name; self.symbol = symbol; self.permissions = permissions
    }
    func start() {}
    func stop() {}
}
