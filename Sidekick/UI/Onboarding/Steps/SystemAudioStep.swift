import Combine
import SwiftUI

struct SystemAudioStep: View {
    let next: @MainActor @Sendable () -> Void
    @State private var granted = Permissions.systemAudio
    @State private var checking = false
    @State private var auto = AutoAdvance()
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        StepLayout(title: "Allow System Audio Recording",
                   message: "Volume Mixer changes an app's volume by passing its sound through Sidekick. Nothing is recorded or saved. Turn on Sidekick under System Audio Recording Only.") {
            if granted { DoneBadge(text: "System Audio Recording allowed") }
        } actions: {
            if granted {
                PrimaryButton(title: "Continue", action: next)
            } else {
                PrimaryButton(title: "Open Settings") { Task { await request() } }
                Button("Later", action: next)
                    .buttonStyle(MonoButtonStyle())
            }
        }
        .task {
            // The verdict is in memory only, so confirm an earlier grant in the background (no
            // prompt). Nothing probes until the button has been pressed once (spike §3).
            guard SystemAudioPermission.hasPrompted, !granted, !checking else { return }
            checking = true
            let state = await SystemAudioPermission.check()
            checking = false
            if state == .granted { markGranted(bringToFront: false) }
        }
        .onReceive(poll) { _ in
            guard SystemAudioPermission.hasPrompted, !granted, !checking else { return }
            checking = true
            Task {
                // A short max age, so a switch flipped in System Settings is noticed within seconds.
                let state = await SystemAudioPermission.check(maxAge: 2)
                checking = false
                if state == .granted { markGranted() }
            }
        }
        .onDisappear { auto.cancel() }
    }

    private func request() async {
        if await SystemAudioPermission.request() == .granted {
            markGranted()
        } else {
            Permissions.openSettings(.systemAudio)
        }
    }

    private func markGranted(bringToFront: Bool = true) {
        guard !granted else { return }
        withAnimation(Motion.fluid) { granted = true }
        // Bring Sidekick back to the front after the user flips the switch in System Settings.
        if bringToFront { AppEnvironment.shared.window.show() }
        auto.schedule(next)
    }
}
