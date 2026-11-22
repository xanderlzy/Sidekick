import Foundation
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
    @ObservationIgnored private let recheck: @MainActor (OnboardingStep) -> (@MainActor () async -> Void)?
    /// The request whose recheck is running; a later request or a cancel supersedes it.
    @ObservationIgnored private var rechecking: Int?
    @ObservationIgnored private var requests = 0

    @ObservationIgnored private let defaults: UserDefaults

    init(registry: ToolRegistry, satisfied: @escaping @MainActor (OnboardingStep) -> Bool = OnboardingFlow.isSatisfied,
         recheck: @escaping @MainActor (OnboardingStep) -> (@MainActor () async -> Void)? = OnboardingFlow.recheck,
         defaults: UserDefaults = .standard) {
        self.registry = registry
        self.satisfied = satisfied
        self.recheck = recheck
        self.defaults = defaults
    }

    /// Tool-specific steps (model download, practice...) run only the first time a tool is set up.
    func isSetupDone(_ id: String) -> Bool { defaults.bool(forKey: "setupDone.\(id)") }
    func markSetupDone(_ id: String) { defaults.set(true, forKey: "setupDone.\(id)") }

    /// What a tool still needs before it can be turned on.
    func setupSteps(for tool: any Tool) -> [OnboardingStep] {
        OnboardingFlow.setupSteps(for: tool, satisfied: satisfied, setupDone: isSetupDone(tool.id))
    }

    /// Turns a tool on, first showing its setup sheet if it needs steps the Mac hasn't satisfied yet.
    /// A missing step whose answer can be confirmed by a quick check (System Audio Recording, whose
    /// verdict lives in memory only) is checked first, so a relaunch doesn't re-show the sheet to a
    /// user who has granted it. Other steps decide at once, as before.
    func request(toolID: String) {
        guard let tool = registry.tools.first(where: { $0.id == toolID }) else { return }
        requests += 1
        rechecking = nil
        let checks = setupSteps(for: tool).compactMap(recheck)
        guard !checks.isEmpty else { decide(tool); return }
        let token = requests
        rechecking = token
        Task { @MainActor in
            for check in checks { await check() }
            guard self.rechecking == token else { return }
            self.rechecking = nil
            self.decide(tool)
        }
    }

    private func decide(_ tool: any Tool) {
        let toolID = tool.id
        if setupSteps(for: tool).isEmpty {
            registry.setEnabled(toolID, true)
        } else {
            if pending != toolID { cancel() }
            pending = toolID
            showWindow()
        }
    }

    /// Ends the sheet without turning its tool on (Cancel, window closed, or replaced by another).
    func cancel() {
        rechecking = nil
        guard let id = pending else { return }
        pending = nil
        if !registry.isEnabled(id), let tool = registry.tools.first(where: { $0.id == id }) { tool.stop() }
    }

    /// Ends the sheet with its tool turned on.
    func complete() {
        guard let id = pending else { return }
        pending = nil
        markSetupDone(id)
        registry.setEnabled(id, true)
    }
}
