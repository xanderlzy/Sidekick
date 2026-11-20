import Testing
import Foundation
@testable import Sidekick

@MainActor
struct ToolRegistryTests {
    private func makeDefaults() -> UserDefaults { UserDefaults(suiteName: UUID().uuidString)! }

    @Test func firstRunEnablesDictation() {
        let registry = ToolRegistry(tools: [FakeTool(id: "other"), FakeTool(id: "dictation")], defaults: makeDefaults())
        #expect(registry.isEnabled("dictation"))
        #expect(!registry.isEnabled("other"))
    }

    @Test func enablingPersists() {
        let defaults = makeDefaults()
        let first = ToolRegistry(tools: [FakeTool(id: "other"), FakeTool(id: "dictation")], defaults: defaults)
        first.setEnabled("other", true)
        first.setEnabled("dictation", false)
        let second = ToolRegistry(tools: [FakeTool(id: "other"), FakeTool(id: "dictation")], defaults: defaults)
        #expect(second.isEnabled("other"))
        #expect(!second.isEnabled("dictation"))
    }

    @Test func startEnabledStartsOnlyEnabledOnce() {
        let other = FakeTool(id: "other"), dictation = FakeTool(id: "dictation")
        let registry = ToolRegistry(tools: [other, dictation], defaults: makeDefaults())
        registry.startEnabled()
        registry.startEnabled()
        #expect(dictation.startCount == 1)
        #expect(other.startCount == 0)
    }

    @Test func noStartBeforeLaunch() {
        let other = FakeTool(id: "other")
        let registry = ToolRegistry(tools: [other, FakeTool(id: "dictation")], defaults: makeDefaults())
        registry.setEnabled("other", true)
        #expect(other.startCount == 0)
    }

    @Test func disablingStopsTool() {
        let dictation = FakeTool(id: "dictation")
        let registry = ToolRegistry(tools: [FakeTool(id: "other"), dictation], defaults: makeDefaults())
        registry.startEnabled()
        registry.setEnabled("dictation", false)
        #expect(dictation.stopCount == 1)
        registry.setEnabled("dictation", false)
        #expect(dictation.stopCount == 1)
    }

    @Test func enabledKeepsRegistryOrder() {
        let defaults = makeDefaults()
        let registry = ToolRegistry(tools: [FakeTool(id: "a"), FakeTool(id: "b")], defaults: defaults, defaultEnabled: [])
        registry.setEnabled("b", true)
        registry.setEnabled("a", true)
        #expect(registry.enabled.map(\.id) == ["a", "b"])
    }
}
