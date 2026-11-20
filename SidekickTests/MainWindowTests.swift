import AppKit
import SwiftUI
import Testing
@testable import Sidekick

@MainActor
struct MainWindowTests {
    /// Onboarding content that fills all available height must not grow the window off-screen.
    @Test func windowStaysOnScreenWithFlexibleContent() async throws {
        let c = MainWindowController { _ in
            AnyView(VStack(alignment: .leading) {
                Text("Hello. Sidekick here.").fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Get started") {}
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        }
        c.show()
        try await Task.sleep(for: .milliseconds(300))
        let frame = try #require(c.windowFrame)
        let screen = try #require(NSScreen.main?.visibleFrame)
        c.close()
        #expect(frame.height <= screen.height)
        #expect(frame.height <= 700)
    }

    @Test func rootWindowFitsOnScreen() async throws {
        let env = AppEnvironment.shared
        let c = MainWindowController { nav in AnyView(RootView(env: env, navigation: nav)) }
        c.show()
        try await Task.sleep(for: .milliseconds(500))
        let frame = try #require(c.windowFrame)
        c.close()
        #expect(frame.height <= 700, "window height \(frame.height)")
    }

    @Test func windowIsFixedSize() async throws {
        let c = MainWindowController { _ in AnyView(Color.clear) }
        c.show()
        let mask = try #require(c.styleMask)
        let frame = try #require(c.windowFrame)
        c.close()
        #expect(!mask.contains(.resizable))
        #expect(frame.size.height >= 560 && frame.size.width == 800)
    }
}
