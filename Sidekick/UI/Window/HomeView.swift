import SwiftUI

/// One card per registered tool, with an on/off switch.
struct HomeView: View {
    let env: AppEnvironment

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Tools").font(Theme.Font.title)
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(env.registry.tools, id: \.id) { tool in card(tool) }
                }
            }
        }
        .scrollIndicators(.never)
    }

    /// The one place a toggle turns into an action. Task 4 reroutes "on" through setup.
    private func setEnabled(_ tool: any Tool, _ on: Bool) {
        env.registry.setEnabled(tool.id, on)
    }

    private func card(_ tool: any Tool) -> some View {
        let binding = Binding(get: { env.registry.isEnabled(tool.id) },
                              set: { setEnabled(tool, $0) })
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: tool.symbol).font(.system(size: 22))
                Spacer()
                Toggle("", isOn: binding).toggleStyle(MonoToggleStyle()).labelsHidden().fixedSize()
            }
            Text(tool.name).font(.system(size: 17, weight: .semibold))
            Text(tool.summary).font(.system(size: 13)).foregroundStyle(Theme.fg(0.55))
                .fixedSize(horizontal: false, vertical: true)
            if !tool.permissions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(tool.permissions, id: \.self) { p in
                        Text(p.title).font(Theme.Font.caption).foregroundStyle(Theme.fg(0.55))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .overlay(Capsule().strokeBorder(Theme.fg(0.12), lineWidth: 1))
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
            .strokeBorder(Theme.fg(0.12), lineWidth: 1))
    }
}
