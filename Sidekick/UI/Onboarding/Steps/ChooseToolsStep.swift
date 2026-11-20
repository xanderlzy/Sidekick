import SwiftUI

/// Compact tool cards with switches. Turning one on here doesn't open its setup sheet,
/// because the steps that follow already cover it.
struct ChooseToolsStep: View {
    let env: AppEnvironment
    let next: () -> Void

    var body: some View {
        StepLayout(title: "Pick your tools",
                   message: "You can change these any time from the menu bar.") {
            VStack(spacing: Theme.Space.item) {
                ForEach(env.registry.tools, id: \.id) { tool in
                    ToolCard(tool: tool, isOn: Binding(get: { env.registry.isEnabled(tool.id) },
                                                       set: { env.registry.setEnabled(tool.id, $0) }),
                             showsPermissions: false)
                }
            }
            .frame(maxWidth: 460)
        } actions: {
            PrimaryButton(title: "Continue", action: next)
        }
    }
}
