import KeyboardShortcuts
import SwiftUI

struct WindowManagerSettingsView: View {
    let tool: WindowManagerTool
    @State private var snapEnabled: Bool

    init(tool: WindowManagerTool) {
        self.tool = tool
        _snapEnabled = State(initialValue: tool.snapEnabled)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                PageHeader("Window Manager")

                SettingsSection("Snapping") {
                    SettingsRow(title: "Snap windows by dragging", detail: "Drag a window to an edge or corner of the screen.") {
                        Toggle("", isOn: snapBinding).toggleStyle(MonoToggleStyle()).labelsHidden()
                    }
                }

                ForEach(WindowAction.Group.allCases, id: \.self) { group in
                    SettingsSection(group.rawValue) {
                        ForEach(WindowAction.allCases.filter { $0.group == group }, id: \.self) { action in
                            SettingsRow(title: action.title) {
                                KeyboardShortcuts.Recorder(for: action.shortcutName)
                            }
                        }
                    }
                }

                Button("Restore default shortcuts") {
                    KeyboardShortcuts.reset(WindowAction.allCases.map(\.shortcutName))
                }
                .buttonStyle(MonoButtonStyle())
                .padding(.bottom, 24)
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    /// The tool's own defaults are the single source of truth; the state only drives redraws.
    private var snapBinding: Binding<Bool> {
        Binding(get: { snapEnabled }, set: { snapEnabled = $0; tool.setSnapping($0) })
    }
}
