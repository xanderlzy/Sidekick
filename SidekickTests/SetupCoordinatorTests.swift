import Foundation
import Testing
@testable import Sidekick

@MainActor
struct SetupCoordinatorTests {
    let a = FakeTool(id: "a", setupSteps: [.microphone])
    let b = FakeTool(id: "b", setupSteps: [.accessibility])
    let registry: ToolRegistry
    let setup: SetupCoordinator

    init() {
        let defaults = UserDefaults(suiteName: "SetupCoordinatorTests-\(UUID())")!
        registry = ToolRegistry(tools: [a, b], defaults: defaults, defaultEnabled: [])
        setup = SetupCoordinator(registry: registry, satisfied: { _ in false }, defaults: defaults)
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

    @Test func completingRecordsSetupDone() {
        setup.request(toolID: "a")
        setup.complete()
        #expect(setup.isSetupDone("a"))
        #expect(!setup.isSetupDone("b"))
    }

    @Test func reEnablingWithPermissionRevokedShowsOnlyPermissionSheet() {
        let t = FakeTool(id: "t", setupSteps: [.microphone, .speechModel])
        let defaults = UserDefaults(suiteName: "SetupCoordinatorTests-\(UUID())")!
        let reg = ToolRegistry(tools: [t], defaults: defaults, defaultEnabled: [])
        let granted = Box(true)
        let s = SetupCoordinator(registry: reg, satisfied: { _ in granted.value }, defaults: defaults)
        s.markSetupDone("t")
        s.request(toolID: "t")
        #expect(reg.isEnabled("t"))
        reg.setEnabled("t", false)
        granted.value = false
        s.request(toolID: "t")
        #expect(s.pending == "t")
        #expect(s.setupSteps(for: t) == [.microphone])
    }
}

@MainActor private final class Box { var value: Bool; init(_ v: Bool) { value = v } }
