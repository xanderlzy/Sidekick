import Testing
import Foundation
@testable import Sidekick

@MainActor
struct ToolRegistryTests {
    private func makeDefaults() -> UserDefaults { UserDefaults(suiteName: UUID().uuidString)! }

    @Test func firstRunUsesDefaultEnabled() {
        let registry = ToolRegistry(tools: [FakeTool(id: "keepOnTop"), FakeTool(id: "dictation")], defaults: makeDefaults())
        #expect(registry.isEnabled("keepOnTop"))
        #expect(!registry.isEnabled("dictation"))
    }

    @Test func enablingPersists() {
        let defaults = makeDefaults()
        let first = ToolRegistry(tools: [FakeTool(id: "keepOnTop"), FakeTool(id: "dictation")], defaults: defaults)
        first.setEnabled("dictation", true)
        let second = ToolRegistry(tools: [FakeTool(id: "keepOnTop"), FakeTool(id: "dictation")], defaults: defaults)
        #expect(second.isEnabled("dictation"))
    }

    @Test func startEnabledStartsOnlyEnabledOnce() {
        let keep = FakeTool(id: "keepOnTop"), dictation = FakeTool(id: "dictation")
        let registry = ToolRegistry(tools: [keep, dictation], defaults: makeDefaults())
        registry.startEnabled()
        registry.startEnabled()
        #expect(keep.startCount == 1)
        #expect(dictation.startCount == 0)
    }

    @Test func noStartBeforeLaunch() {
        let dictation = FakeTool(id: "dictation")
        let registry = ToolRegistry(tools: [FakeTool(id: "keepOnTop"), dictation], defaults: makeDefaults())
        registry.setEnabled("dictation", true)
        #expect(dictation.startCount == 0)
    }

    @Test func disablingStopsTool() {
        let keep = FakeTool(id: "keepOnTop")
        let registry = ToolRegistry(tools: [keep, FakeTool(id: "dictation")], defaults: makeDefaults())
        registry.startEnabled()
        registry.setEnabled("keepOnTop", false)
        #expect(keep.stopCount == 1)
        registry.setEnabled("keepOnTop", false)
        #expect(keep.stopCount == 1)
    }

    @Test func enabledKeepsRegistryOrder() {
        let defaults = makeDefaults()
        let registry = ToolRegistry(tools: [FakeTool(id: "a"), FakeTool(id: "b")], defaults: defaults, defaultEnabled: [])
        registry.setEnabled("b", true)
        registry.setEnabled("a", true)
        #expect(registry.enabled.map(\.id) == ["a", "b"])
    }
}
