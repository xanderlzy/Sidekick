import SwiftUI

/// Covers the main window with one tool's missing setup steps. Esc or Cancel leaves the tool off.
struct SetupSheet: View {
    let env: AppEnvironment
    let tool: any Tool
    let steps: [OnboardingStep]

    var body: some View {
        OnboardingView(env: env, steps: steps, cancel: { env.pendingSetup = nil }) {
            env.registry.setEnabled(tool.id, true)
            env.pendingSetup = nil
        }
    }
}
