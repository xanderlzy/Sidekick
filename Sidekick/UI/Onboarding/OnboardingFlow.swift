enum OnboardingStep: String, Sendable {
    case welcome, chooseTools, microphone, accessibility
    case speechModel, appleIntelligence, globeKey, practice, tryIt, finish
}

extension OnboardingStep {
    /// Steps that ask for a system permission (always re-checked), as opposed to one-time tool setup.
    var isPermission: Bool { self == .microphone || self == .accessibility }
}

/// Pure step sequencing for first-run setup and per-tool setup.
struct OnboardingFlow {
    private(set) var steps: [OnboardingStep]
    private(set) var index: Int
    private(set) var forward = true

    init(steps: [OnboardingStep]) {
        self.steps = steps
        index = 0
    }

    /// Welcome, tool picker, each enabled tool's steps (deduped, minus satisfied), finish.
    @MainActor static func steps(tools: [any Tool], satisfied: (OnboardingStep) -> Bool) -> [OnboardingStep] {
        var seen = Set<OnboardingStep>()
        let toolSteps = tools.flatMap(\.setupSteps).filter { seen.insert($0).inserted && !satisfied($0) }
        return [.welcome, .chooseTools] + toolSteps + [.finish]
    }

    /// Steps still needed before one tool can be turned on. Empty means no sheet.
    /// Once a tool's setup has been completed (`setupDone`), only its missing permissions are asked for.
    @MainActor static func setupSteps(for tool: any Tool, satisfied: (OnboardingStep) -> Bool,
                                      setupDone: Bool = false) -> [OnboardingStep] {
        tool.setupSteps.filter { !satisfied($0) && (!setupDone || $0.isPermission) }
    }

    /// True only for permission steps whose permission is already granted.
    @MainActor static func isSatisfied(_ step: OnboardingStep) -> Bool {
        switch step {
        case .microphone: Permissions.microphone
        case .accessibility: Permissions.accessibility
        default: false
        }
    }

    var current: OnboardingStep { steps[index] }
    var count: Int { steps.count }
    var canGoBack: Bool { index > 0 }
    var isLast: Bool { index == steps.count - 1 }

    /// Swaps the remaining steps (after the tool picker) while keeping the current one.
    mutating func replaceSteps(_ new: [OnboardingStep]) {
        let keep = current
        steps = new
        index = new.firstIndex(of: keep) ?? min(index, new.count - 1)
    }

    /// True while the flow is still on `step`, so a delayed advance scheduled by that step can't skip another.
    func canAdvance(from step: OnboardingStep) -> Bool { current == step }

    mutating func next() { forward = true; index = min(index + 1, steps.count - 1) }
    mutating func back() { forward = false; index = max(index - 1, 0) }
}
