import SwiftUI
@testable import Sidekick

@MainActor
final class FakeTool: Tool {
    let id: String
    let name: String
    let symbol = "circle"
    let summary = "Fake"
    let permissions: [Permission] = []
    let setupSteps: [OnboardingStep] = []
    let pages: [ToolPage] = []
    let menuItems: [ToolMenuItem] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(id: String) {
        self.id = id
        self.name = id
    }

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
}
