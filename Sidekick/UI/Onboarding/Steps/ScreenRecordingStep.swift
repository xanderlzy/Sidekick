import Combine
import SwiftUI

struct ScreenRecordingStep: View {
    let env: AppEnvironment
    let next: () -> Void
    @State private var granted = Permissions.screenRecording
    @State private var asked = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        StepLayout(title: "Let Keep on Top see your windows",
                   message: "Screen Recording lets Sidekick show a live copy of the window you pin. Nothing is saved or sent anywhere.") {
            if granted { DoneBadge(text: "Screen Recording allowed") }
        } actions: {
            if granted {
                PrimaryButton(title: "Continue", action: next)
            } else {
                PrimaryButton(title: "Open Screen Recording Settings") {
                    asked = true
                    Permissions.requestScreenRecording()
                    Permissions.openSettings(.screenRecording)
                }
                if asked {
                    // The permission often only takes effect on a fresh launch. Setup resumes on this step.
                    Button("Quit & Reopen") { Relauncher.relaunch() }
                        .buttonStyle(MonoButtonStyle())
                        .transition(.opacity)
                }
            }
        }
        .animation(Motion.snappy, value: asked)
        .onReceive(poll) { _ in
            guard Permissions.screenRecording, !granted else { return }
            withAnimation(Motion.fluid) { granted = true }
            // Bring Sidekick back to the front after the user flips the switch in System Settings.
            env.window.show()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.9))
                next()
            }
        }
    }
}
