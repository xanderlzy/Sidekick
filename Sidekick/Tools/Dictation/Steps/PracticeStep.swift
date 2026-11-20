import SwiftUI

/// Teaches hold-to-talk and double-tap-to-lock with a live on-screen key. Dictation is paused
/// during practice.
struct PracticeStep: View {
    let env: DictationEnvironment
    let key: HotkeyKey
    let next: () -> Void
    enum Phase { case hold, doubleTap, finishLock, done }
    @State private var phase: Phase = .hold
    @State private var pressed = false

    var body: some View {
        StepLayout(title: title, message: message) {
            KeyCap(label: key == .fn ? "fn" : key.shortName, pressed: pressed, done: phase == .done)
        } actions: {
            if phase == .done {
                PrimaryButton(title: "Continue", action: next)
            } else {
                Button("Skip") { next() }.buttonStyle(MonoButtonStyle())
            }
        }
        .onAppear {
            env.startHotkeys()
            env.keyStateObserver = { down in withAnimation(Motion.snappy) { pressed = down } }
            env.hotkeyInterceptor = { action in
                withAnimation(Motion.fluid) {
                    switch (phase, action) {
                    case (.hold, .commit): phase = .doubleTap
                    case (.doubleTap, .lock): phase = .finishLock
                    case (.finishLock, .commit): phase = .done
                    case (.finishLock, .cancel): phase = .doubleTap
                    default: break
                    }
                }
            }
        }
        .onDisappear {
            env.hotkeyInterceptor = nil
            env.keyStateObserver = nil
        }
    }

    private var title: String {
        switch phase {
        case .hold: "Hold \(key.shortName) for a moment"
        case .doubleTap: "Now double-tap \(key.shortName)"
        case .finishLock: "Hands-free is on"
        case .done: "You've got it"
        }
    }

    private var message: String {
        switch phase {
        case .hold: "Holding the key is how you talk. Let go when you're done."
        case .doubleTap: "Two quick taps lock listening on, so you can talk without holding anything."
        case .finishLock: "Tap \(key.shortName) once more to finish."
        case .done: "Hold to talk, double-tap for hands-free, Esc to cancel."
        }
    }
}

private struct KeyCap: View {
    let label: String
    let pressed: Bool
    let done: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(pressed || done ? Theme.fg() : Theme.bg())
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.fg(0.8), lineWidth: 1.5))
                .shadow(color: .black.opacity(pressed ? 0 : 0.12), radius: 0, y: pressed ? 0 : 4)
            Text(label)
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .foregroundStyle(pressed || done ? Theme.bg() : Theme.fg())
        }
        .frame(width: 88, height: 80)
        .offset(y: pressed ? 4 : 0)
        .scaleEffect(done ? 1.05 : 1)
    }
}
