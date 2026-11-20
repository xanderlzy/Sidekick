import KeyboardShortcuts
import SwiftUI

struct FinishStep: View {
    let env: AppEnvironment
    let done: () -> Void
    @State private var launchAtLogin = true

    private var shortcuts: [(id: String, title: String, keys: String)] {
        env.registry.enabled.flatMap(\.menuItems).compactMap { item in
            item.shortcut.map { (item.id, item.title, KeyboardShortcuts.getShortcut(for: $0)?.description ?? "Not set") }
        }
    }

    var body: some View {
        StepLayout(title: "You're all set",
                   message: "Sidekick lives in your menu bar.") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(shortcuts, id: \.id) { s in
                    HStack {
                        Text(s.title).font(.system(size: 14))
                        Spacer()
                        Text(s.keys).font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.fg(0.55))
                    }
                }
                Toggle(isOn: $launchAtLogin) {
                    Text("Launch Sidekick at login").font(.system(size: 14))
                }
                .toggleStyle(MonoToggleStyle())
            }
            .frame(maxWidth: 360)
        } actions: {
            PrimaryButton(title: "Done") {
                try? LoginItem.set(launchAtLogin)
                done()
            }
        }
    }
}
