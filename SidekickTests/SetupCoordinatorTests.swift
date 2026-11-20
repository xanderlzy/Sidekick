import Foundation
import Testing
@testable import Sidekick

@MainActor
struct SetupCoordinatorTests {
    let a = FakeTool(id: "a", setupSteps: [.microphone])
    let b = FakeTool(id: "b", setupSteps: [.screenRecording])
    let registry: ToolRegistry
    let setup: SetupCoordinator

    init() {
        let defaults = UserDefaults(suiteName: "SetupCoordinatorTests-\(UUID())")!
        registry = ToolRegistry(tools: [a, b], defaults: defaults, defaultEnabled: [])
        setup = SetupCoordinator(registry: registry, satisfied: { _ in false })
    }

    @Test func requestShowsSheetForUnsatisfiedSteps() {
        var shown = 0
        setup.showWindow = { shown += 1 }
        setup.request(toolID: "a")
        #expect(setup.pending == "a")
        #expect(shown == 1)
    }

    @Test func cancellingStopsToolThatIsNotEnabled() {
        setup.request(toolID: "a")
        setup.cancel()
        #expect(setup.pending == nil)
        #expect(a.stopCount == 1)
    }

    @Test func cancellingLeavesEnabledToolRunning() {
        registry.setEnabled("a", true)
        setup.request(toolID: "a")
        setup.cancel()
        #expect(a.stopCount == 0)
    }

    @Test func requestingAnotherToolAbandonsPendingSetup() {
        setup.request(toolID: "a")
        setup.request(toolID: "b")
        #expect(setup.pending == "b")
        #expect(a.stopCount == 1)
        #expect(b.stopCount == 0)
    }

    @Test func requestingSameToolAgainKeepsIt() {
        setup.request(toolID: "a")
        setup.request(toolID: "a")
        #expect(setup.pending == "a")
        #expect(a.stopCount == 0)
    }

    @Test func completingEnablesWithoutStopping() {
        setup.request(toolID: "a")
        setup.complete()
        #expect(setup.pending == nil)
        #expect(registry.isEnabled("a"))
        #expect(a.stopCount == 0)
    }

    @Test func cancelWithNothingPendingDoesNothing() {
        setup.cancel()
        #expect(a.stopCount == 0 && b.stopCount == 0)
    }

    @Test func toolWithNoMissingStepsTurnsOnDirectly() {
        let setup = SetupCoordinator(registry: registry, satisfied: { _ in true })
        setup.request(toolID: "a")
        #expect(setup.pending == nil)
        #expect(registry.isEnabled("a"))
    }
}
