import SwiftUI

/// One full-width card per registered tool, with an on/off switch. A single column reads the same
/// with one tool or many, and every card shares one internal layout.
struct HomeView: View {
    let env: AppEnvironment

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                PageHeader("Tools", subtitle: "Turn on what you need. Each tool asks only for what it uses.")
                VStack(spacing: Theme.Space.item) {
                    ForEach(env.registry.tools, id: \.id) { tool in
                        ToolCard(tool: tool, isOn: Binding(get: { env.registry.isEnabled(tool.id) },
                                                           set: { setEnabled(tool, $0) }))
                    }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    /// The one place a toggle turns into an action. Turning on goes through setup; off is immediate.
    private func setEnabled(_ tool: any Tool, _ on: Bool) {
        if on { env.requestSetup(toolID: tool.id) } else { env.registry.setEnabled(tool.id, false) }
    }
}
