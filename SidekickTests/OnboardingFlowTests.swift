import Foundation
import Testing
@testable import Sidekick

@MainActor
struct OnboardingFlowTests {
    private let none: (OnboardingStep) -> Bool = { _ in false }
    private func listener() -> FakeTool { FakeTool(id: "listener", setupSteps: [.microphone]) }
    private func dictation() -> FakeTool {
        FakeTool(id: "dictation", setupSteps: [.microphone, .accessibility, .speechModel])
    }

    @Test func singleToolSteps() {
        #expect(OnboardingFlow.steps(tools: [listener()], satisfied: none)
                == [.welcome, .chooseTools, .microphone, .finish])
    }

    @Test func bothToolsInRegistryOrderDeduped() {
        #expect(OnboardingFlow.steps(tools: [listener(), dictation()], satisfied: none)
                == [.welcome, .chooseTools, .microphone, .accessibility, .speechModel, .finish])
    }

    @Test func grantedPermissionsSkipped() {
        #expect(OnboardingFlow.steps(tools: [listener()], satisfied: { $0 == .microphone })
                == [.welcome, .chooseTools, .finish])
    }

    @Test func startsAtFirstStep() {
        let flow = OnboardingFlow(steps: [.welcome, .chooseTools, .finish])
        #expect(flow.current == .welcome)
        #expect(!flow.canGoBack)
    }

    @Test func replaceStepsKeepsCurrent() {
        var flow = OnboardingFlow(steps: [.welcome, .chooseTools, .finish])
        flow.next()
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
                == [.accessibility, .speechModel])
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
        var flow = OnboardingFlow(steps: [.welcome, .microphone, .accessibility, .finish])
        flow.next()
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
