import Foundation
import Testing
@testable import Sidekick

@MainActor
struct OnboardingFlowTests {
    private let none: (OnboardingStep) -> Bool = { _ in false }
    private func keepOnTop() -> FakeTool { FakeTool(id: "keepOnTop", setupSteps: [.screenRecording]) }
    private func dictation() -> FakeTool {
        FakeTool(id: "dictation", setupSteps: [.microphone, .accessibility, .screenRecording])
    }

    @Test func keepOnTopOnly() {
        #expect(OnboardingFlow.steps(tools: [keepOnTop()], satisfied: none)
                == [.welcome, .chooseTools, .screenRecording, .finish])
    }

    @Test func bothToolsInRegistryOrderDeduped() {
        #expect(OnboardingFlow.steps(tools: [keepOnTop(), dictation()], satisfied: none)
                == [.welcome, .chooseTools, .screenRecording, .microphone, .accessibility, .finish])
    }

    @Test func grantedPermissionsSkipped() {
        #expect(OnboardingFlow.steps(tools: [keepOnTop()], satisfied: { $0 == .screenRecording })
                == [.welcome, .chooseTools, .finish])
    }

    @Test func resumesAtSavedStep() {
        let s = OnboardingFlow.steps(tools: [keepOnTop()], satisfied: none)
        let flow = OnboardingFlow(steps: s, resumeAt: .screenRecording)
        #expect(flow.current == .screenRecording)
        #expect(flow.canGoBack)
    }

    @Test func replaceStepsKeepsCurrent() {
        var flow = OnboardingFlow(steps: [.welcome, .chooseTools, .finish], resumeAt: .chooseTools)
        flow.replaceSteps([.welcome, .chooseTools, .microphone, .finish])
        #expect(flow.current == .chooseTools)
        flow.next()
        #expect(flow.current == .microphone)
    }

    @Test func miniFlowEmptyWhenAllGranted() {
        #expect(OnboardingFlow.setupSteps(for: dictation(), satisfied: { _ in true }).isEmpty)
    }

    @Test func miniFlowSkipsOnlySatisfied() {
        #expect(OnboardingFlow.setupSteps(for: dictation(), satisfied: { $0 == .microphone })
                == [.accessibility, .screenRecording])
    }

    @Test func reEnableWithAllGrantedNeedsNoSheet() {
        let tool = FakeTool(id: "d", setupSteps: [.microphone, .accessibility, .speechModel, .practice, .tryIt])
        #expect(OnboardingFlow.setupSteps(for: tool, satisfied: { $0.isPermission }, setupDone: true).isEmpty)
    }

    @Test func reEnableWithRevokedPermissionAsksOnlyForThat() {
        let tool = FakeTool(id: "d", setupSteps: [.microphone, .accessibility, .speechModel, .practice, .tryIt])
        #expect(OnboardingFlow.setupSteps(for: tool, satisfied: { $0 == .microphone }, setupDone: true)
                == [.accessibility])
    }

    @Test func firstSetupKeepsToolSteps() {
        let tool = FakeTool(id: "d", setupSteps: [.microphone, .accessibility, .speechModel, .practice, .tryIt])
        #expect(OnboardingFlow.setupSteps(for: tool, satisfied: { $0.isPermission }, setupDone: false)
                == [.speechModel, .practice, .tryIt])
    }

    @Test func advanceOnlyFromTheCurrentStep() {
        var flow = OnboardingFlow(steps: [.welcome, .microphone, .accessibility, .finish], resumeAt: .microphone)
        #expect(flow.canAdvance(from: .microphone))
        flow.next()
        #expect(!flow.canAdvance(from: .microphone))
        #expect(flow.canAdvance(from: .accessibility))
    }

    @Test func nextAndBackStayInBounds() {
        var flow = OnboardingFlow(steps: [.welcome, .finish])
        flow.back()
        #expect(flow.index == 0)
        flow.next(); flow.next()
        #expect(flow.index == 1 && flow.isLast)
    }

    @Test func movingForwardSetsDirection() {
        var flow = OnboardingFlow(steps: [.welcome, .chooseTools, .finish])
        flow.next()
        #expect(flow.forward)
        flow.back()
        #expect(!flow.forward)
    }
}

@MainActor
struct LaunchTests {
    @Test func windowShowsAtLaunchOnlyBeforeOnboardingCompletes() {
        let d = UserDefaults(suiteName: "LaunchTests")!
        d.removePersistentDomain(forName: "LaunchTests")
        #expect(AppDelegate.shouldShowWindowAtLaunch(defaults: d))
        d.set(true, forKey: "onboardingComplete")
        #expect(!AppDelegate.shouldShowWindowAtLaunch(defaults: d))
    }
}
