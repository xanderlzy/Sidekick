import Observation

/// Tracks the one tool whose setup sheet is showing. Setup steps may start a tool before it's
/// turned on (Dictation's need it running), so every way a sheet ends without finishing
/// stops a tool the registry doesn't consider on.
@MainActor @Observable
final class SetupCoordinator {
    /// ID of the tool whose setup sheet is showing.
    private(set) var pending: String?
    @ObservationIgnored var showWindow: () -> Void = {}
    @ObservationIgnored private let registry: ToolRegistry
    @ObservationIgnored private let satisfied: @MainActor (OnboardingStep) -> Bool

    init(registry: ToolRegistry, satisfied: @escaping @MainActor (OnboardingStep) -> Bool = OnboardingFlow.isSatisfied) {
        self.registry = registry
        self.satisfied = satisfied
    }

    /// Turns a tool on, first showing its setup sheet if it needs steps the Mac hasn't satisfied yet.
    func request(toolID: String) {
        guard let tool = registry.tools.first(where: { $0.id == toolID }) else { return }
        if OnboardingFlow.setupSteps(for: tool, satisfied: satisfied).isEmpty {
            registry.setEnabled(toolID, true)
        } else {
            if pending != toolID { cancel() }
            pending = toolID
            showWindow()
        }
    }

    /// Ends the sheet without turning its tool on (Cancel, window closed, or replaced by another).
    func cancel() {
        guard let id = pending else { return }
        pending = nil
        if !registry.isEnabled(id), let tool = registry.tools.first(where: { $0.id == id }) { tool.stop() }
    }

    /// Ends the sheet with its tool turned on.
    func complete() {
        guard let id = pending else { return }
        pending = nil
        registry.setEnabled(id, true)
    }
}
