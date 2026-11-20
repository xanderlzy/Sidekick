import AppKit
import SwiftUI

@MainActor @Observable
final class AppNavigation {
    var route: Route = .home
}

/// Owns the single main window. Sidekick shows a Dock icon only while it's open.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    let navigation = AppNavigation()
    private var window: NSWindow?
    private let makeContent: (AppNavigation) -> AnyView
    var onClose: () -> Void = {}

    init(makeContent: @escaping (AppNavigation) -> AnyView) {
        self.makeContent = makeContent
    }

    var isVisible: Bool { window?.isVisible ?? false }
    var windowFrame: NSRect? { window?.frame }
    var styleMask: NSWindow.StyleMask? { window?.styleMask }

    func show(_ route: Route? = nil) {
        if let route { navigation.route = route }
        let window = self.window ?? build()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() { window?.performClose(nil) }

    private func build() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.title = "Sidekick"
        let host = NSHostingView(rootView: makeContent(navigation))
        // The window owns its size. Left on, SwiftUI resizes it to the content's ideal size,
        // which for flexible pages is thousands of points tall (off-screen buttons).
        host.sizingOptions = []
        w.contentView = host
        w.center()
        w.delegate = self
        return w
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
        NSApp.setActivationPolicy(.accessory)
    }
}

/// The window's root.
struct RootView: View {
    let env: AppEnvironment
    let navigation: AppNavigation

    @AppStorage("onboardingComplete") private var onboardingComplete = false

    var body: some View {
        ZStack {
            if onboardingComplete {
                MainWindow(env: env, navigation: navigation).transition(.opacity)
            } else {
                OnboardingView.firstRun(env: env) {
                    for tool in env.registry.enabled { env.setup.markSetupDone(tool.id) }
                    withAnimation(Motion.gentle) { onboardingComplete = true }
                    navigation.route = .home
                    env.window.close()
                }
                .transition(.opacity)
            }
        }
    }
}

/// Sidebar + content, both built from the tool registry.
struct MainWindow: View {
    let env: AppEnvironment
    @Bindable var navigation: AppNavigation

    private var registry: ToolRegistry { env.registry }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(items: SidebarModel.items(for: registry.enabled), navigation: navigation)
            Rectangle().fill(Theme.fg(0.06)).frame(width: 1)
            ZStack { content }
                .id(navigation.route)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 56).padding(.horizontal, 40).padding(.bottom, 28)
        }
        .overlay {
            if let id = env.setup.pending, let tool = registry.tools.first(where: { $0.id == id }) {
                SetupSheet(env: env,
                           steps: env.setup.setupSteps(for: tool))
                    .transition(.opacity)
            }
        }
        .animation(Motion.fluid, value: env.setup.pending)
        .animation(Motion.fluid, value: navigation.route)
        .animation(Motion.fluid, value: registry.enabled.map(\.id))
        .onChange(of: registry.enabled.map(\.id)) { _, _ in
            navigation.route = SidebarModel.validated(navigation.route, tools: registry.enabled)
        }
        .foregroundStyle(Theme.fg())
        .background(Theme.bg())
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var content: some View {
        switch navigation.route {
        case .home: HomeView(env: env)
        case .general: GeneralSettingsView(env: env)
        case let .page(toolID, pageID):
            if let page = registry.enabled.first(where: { $0.id == toolID })?.pages.first(where: { $0.id == pageID }) {
                page.content()
            }
        }
    }
}

/// Wordmark: a filled rounded square and the name.
struct SidekickMark: View {
    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2.5).fill(Theme.fg()).frame(width: 9, height: 9)
            Text("Sidekick").font(.system(size: 15, weight: .semibold)).tracking(-0.2)
        }
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
}
