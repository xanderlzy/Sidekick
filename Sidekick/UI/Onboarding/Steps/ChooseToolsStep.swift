import SwiftUI

/// Compact tool cards with switches. Turning one on here doesn't open its setup sheet,
/// because the steps that follow already cover it.
struct ChooseToolsStep: View {
    let env: AppEnvironment
    let next: () -> Void

    var body: some View {
        StepLayout(title: "Pick your tools",
                   message: "You can change these any time from the menu bar.") {
            VStack(spacing: 10) {
                ForEach(env.registry.tools, id: \.id) { tool in row(tool) }
            }
            .frame(maxWidth: 460)
        } actions: {
            PrimaryButton(title: "Continue", action: next)
        }
    }

    private func row(_ tool: any Tool) -> some View {
        let binding = Binding(get: { env.registry.isEnabled(tool.id) },
                              set: { env.registry.setEnabled(tool.id, $0) })
        return HStack(spacing: 14) {
            Image(systemName: tool.symbol).font(.system(size: 18)).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name).font(.system(size: 14, weight: .semibold))
                Text(tool.summary).font(.system(size: 12)).foregroundStyle(Theme.fg(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: binding).toggleStyle(MonoToggleStyle()).labelsHidden().fixedSize()
        }
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
            .strokeBorder(Theme.fg(0.12), lineWidth: 1))
    }
}
