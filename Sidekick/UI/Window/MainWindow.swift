import AppKit
import SwiftUI

/// Placeholder until the tool registry (Task 3) defines real routes.
enum Route: Hashable {
    case home
}

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
        NSApp.setActivationPolicy(.accessory)
    }
}

/// The window's root. Temporarily just the empty main window.
struct RootView: View {
    let env: AppEnvironment
    let navigation: AppNavigation

    var body: some View {
        MainWindow(env: env, navigation: navigation)
    }
}

/// Empty shell: wordmark and version, no content yet.
struct MainWindow: View {
    let env: AppEnvironment
    let navigation: AppNavigation

    var body: some View {
        VStack(alignment: .leading) {
            SidekickMark()
            Spacer()
            Text("v\(Bundle.main.shortVersion)")
                .font(Theme.Font.caption).foregroundStyle(Theme.fg(0.3))
        }
        .padding(.top, 56).padding(.horizontal, 40).padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(Theme.fg())
        .background(Theme.bg())
        .ignoresSafeArea()
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
