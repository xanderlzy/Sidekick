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
    func start()
    func stop()
}
