import SwiftUI

/// Full-window setup flow: one idea per screen, one primary action.
/// Runs first-run setup (`resumable`, remembers its step) or one tool's mini-flow (`cancel` set).
struct OnboardingView: View {
    static let savedStepKey = "onboardingStep"

    let env: AppEnvironment
    let resumable: Bool
    let done: () -> Void
    let cancel: (() -> Void)?
    @State private var flow: OnboardingFlow

    init(env: AppEnvironment, steps: [OnboardingStep], resumeAt: OnboardingStep? = nil, resumable: Bool = false,
         cancel: (() -> Void)? = nil, done: @escaping () -> Void) {
        self.env = env
        self.resumable = resumable
        self.cancel = cancel
        self.done = done
        _flow = State(initialValue: OnboardingFlow(steps: steps, resumeAt: resumeAt))
    }

    /// First-run setup, resuming at the saved step (also settable with `-onboardingStep <name>`).
    static func firstRun(env: AppEnvironment, done: @escaping () -> Void) -> OnboardingView {
        let steps = OnboardingFlow.steps(tools: env.registry.enabled, satisfied: OnboardingFlow.isSatisfied)
        let saved = UserDefaults.standard.string(forKey: savedStepKey).flatMap(OnboardingStep.init(rawValue:))
        // A saved step that has since been satisfied (permission granted) resumes at the next one.
        let resume = saved.map { steps.contains($0) ? $0 : steps[2] }
        return OnboardingView(env: env, steps: steps, resumeAt: resume, resumable: true, done: done)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                SidekickMark()
                Spacer()
                if flow.canGoBack && flow.current != .finish {
                    Button { withAnimation(Motion.fluid) { flow.back() } } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                            Text("Back")
                        }
                        .font(Theme.Font.caption).foregroundStyle(Theme.fg(0.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale())
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .transition(.opacity)
                }
                if let cancel {
                    Button(action: cancel) {
                        Text("Cancel").font(Theme.Font.caption).foregroundStyle(Theme.fg(0.5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale())
                    .keyboardShortcut(.cancelAction)
                }
                ProgressDots(count: flow.count, index: flow.index)
            }
            .padding(.bottom, 48)

            ZStack(alignment: .topLeading) {
                step(flow.current)
                    .id(flow.index)
                    .transition(.asymmetric(
                        insertion: .offset(x: flow.forward ? 40 : -40).combined(with: .opacity),
                        removal: .offset(x: flow.forward ? -40 : 40).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.top, 56).padding(.horizontal, 64).padding(.bottom, 32)
        .foregroundStyle(Theme.fg())
        .background(Theme.bg())
        .ignoresSafeArea()
        .onChange(of: flow.current, initial: true) { _, step in save(step) }
    }

    private func save(_ step: OnboardingStep) {
        guard resumable else { return }
        if step == .finish {
            UserDefaults.standard.removeObject(forKey: Self.savedStepKey)
        } else {
            UserDefaults.standard.set(step.rawValue, forKey: Self.savedStepKey)
        }
    }

    /// Advances; past the last step of a mini-flow, completes it.
    private func next() {
        if flow.isLast { done() } else { withAnimation(Motion.fluid) { flow.next() } }
    }

    private func toolsChosen() {
        flow.replaceSteps(OnboardingFlow.steps(tools: env.registry.enabled, satisfied: OnboardingFlow.isSatisfied))
        next()
    }

    @ViewBuilder private func step(_ s: OnboardingStep) -> some View {
        switch s {
        case .welcome: WelcomeStep(next: next)
        case .chooseTools: ChooseToolsStep(env: env, next: toolsChosen)
        case .screenRecording: ScreenRecordingStep(env: env, next: next)
        case .finish: FinishStep(env: env, done: done)
        case .microphone: MicrophoneStep(next: next)
        case .globeKey: GlobeKeyStep(next: next)
        case .accessibility: dictationStep { AccessibilityStep(env: $0, next: next) }
        case .speechModel: dictationStep { SpeechModelStep(env: $0, next: next) }
        case .appleIntelligence: dictationStep { AppleIntelligenceStep(env: $0, next: next) }
        case .practice: dictationStep { PracticeStep(env: $0, key: $0.hotkeys.key, next: next) }
        case .tryIt: dictationStep { TryItStep(key: $0.hotkeys.key, next: next) }
        }
    }

    private func dictationStep<Content: View>(@ViewBuilder _ content: @escaping (DictationEnvironment) -> Content) -> some View {
        DictationStepHost(tool: env.registry.tools.lazy.compactMap { $0 as? DictationTool }.first, content: content)
    }
}

/// Starts Dictation (if it isn't running yet) before showing a step that needs its environment.
private struct DictationStepHost<Content: View>: View {
    let tool: DictationTool?
    let content: (DictationEnvironment) -> Content
    @State private var env: DictationEnvironment?

    var body: some View {
        if let env = env ?? tool?.env {
            content(env)
        } else {
            Color.clear.onAppear {
                tool?.start()
                env = tool?.env
            }
        }
    }
}

/// Shared layout for a step: headline, one line of copy, custom content, actions.
struct StepLayout<Content: View, Actions: View>: View {
    let title: String
    let message: String
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 34, weight: .semibold))
                .tracking(-0.8)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(Theme.fg(0.55))
                .frame(maxWidth: 460, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            content.padding(.top, 32)
            Spacer(minLength: 24)
            HStack(spacing: 10) { actions }
        }
    }
}

struct PrimaryButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 22).padding(.vertical, 10)
                .foregroundStyle(Theme.bg())
                .background(Capsule().fill(Theme.fg()))
        }
        .buttonStyle(PressScale())
        .keyboardShortcut(.defaultAction)
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

/// A row confirming something is done, with a checkmark that draws itself in.
struct DoneBadge: View {
    let text: String
    @State private var drawn = false
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.fg()).frame(width: 22, height: 22)
                CheckShape().trim(from: 0, to: drawn ? 1 : 0)
                    .stroke(Theme.bg(), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .frame(width: 10, height: 8)
            }
            .scaleEffect(drawn ? 1 : 0.4)
            Text(text).font(.system(size: 14, weight: .medium))
        }
        .onAppear { withAnimation(Motion.fluid) { drawn = true } }
    }
}

private struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.38, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}

private struct ProgressDots: View {
    let count: Int
    let index: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(Theme.fg(i <= index ? 1 : 0.15))
                    .frame(width: i == index ? 18 : 6, height: 6)
            }
        }
        .animation(Motion.fluid, value: index)
    }
}
