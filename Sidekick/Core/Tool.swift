import SwiftUI
import KeyboardShortcuts

struct ToolPage: Identifiable {
    let id: String
    let title: String
    let content: @MainActor () -> AnyView
}

struct ToolMenuItem: Identifiable {
    let id: String
    let title: String
    let shortcut: KeyboardShortcuts.Name?
    let action: @MainActor () -> Void
    /// Whether the first-run "all set" screen lists this item's shortcut.
    var inCheatSheet: Bool = true
}

@MainActor
protocol Tool: AnyObject {
    var id: String { get }
    var name: String { get }
    var symbol: String { get }
    var summary: String { get }
    var permissions: [Permission] { get }
    /// Permission and tool-specific onboarding steps, in order.
    var setupSteps: [OnboardingStep] { get }
    var pages: [ToolPage] { get }
    var menuItems: [ToolMenuItem] { get }
    /// When set, the tool's menu items go in a submenu with this title.
    var menuTitle: String? { get }
    func start()
    func stop()
    /// Called when the shared Accessibility setup step sees the permission granted.
    func accessibilityGranted()
}

extension Tool {
    var menuTitle: String? { nil }
    func accessibilityGranted() {}
}
