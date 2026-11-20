import SwiftUI
@testable import Sidekick

@MainActor
final class FakeTool: Tool {
    let id: String
    var name: String
    let symbol = "circle"
    let summary = "Fake"
    let permissions: [Permission] = []
    var setupSteps: [OnboardingStep] = []
    var pages: [ToolPage] = []
    let menuItems: [ToolMenuItem] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(id: String, name: String? = nil, pageIDs: [(String, String)] = [], setupSteps: [OnboardingStep] = []) {
        self.id = id
        self.setupSteps = setupSteps
        self.name = name ?? id
        self.pages = pageIDs.map { ToolPage(id: $0.0, title: $0.1) { AnyView(EmptyView()) } }
    }

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
}
