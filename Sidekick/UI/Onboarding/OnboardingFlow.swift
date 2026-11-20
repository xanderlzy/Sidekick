enum OnboardingStep: String, Sendable {
    case welcome, chooseTools, screenRecording, microphone, accessibility
    case speechModel, appleIntelligence, globeKey, practice, tryIt, finish
}

/// Pure step sequencing for first-run setup and per-tool setup.
struct OnboardingFlow {
    private(set) var steps: [OnboardingStep]
    private(set) var index: Int
    private(set) var forward = true

    init(steps: [OnboardingStep], resumeAt: OnboardingStep? = nil) {
        self.steps = steps
        index = resumeAt.flatMap { steps.firstIndex(of: $0) } ?? 0
    }

    /// Welcome, tool picker, each enabled tool's steps (deduped, minus satisfied), finish.
    @MainActor static func steps(tools: [any Tool], satisfied: (OnboardingStep) -> Bool) -> [OnboardingStep] {
        var seen = Set<OnboardingStep>()
        let toolSteps = tools.flatMap(\.setupSteps).filter { seen.insert($0).inserted && !satisfied($0) }
        return [.welcome, .chooseTools] + toolSteps + [.finish]
    }

    /// Steps still needed before one tool can be turned on. Empty means no sheet.
    @MainActor static func setupSteps(for tool: any Tool, satisfied: (OnboardingStep) -> Bool) -> [OnboardingStep] {
        tool.setupSteps.filter { !satisfied($0) }
    }

    /// True only for permission steps whose permission is already granted.
    @MainActor static func isSatisfied(_ step: OnboardingStep) -> Bool {
        switch step {
        case .screenRecording: Permissions.screenRecording
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

    mutating func next() { forward = true; index = min(index + 1, steps.count - 1) }
    mutating func back() { forward = false; index = max(index - 1, 0) }
}
