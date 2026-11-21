import KeyboardShortcuts
import SwiftUI

struct WindowManagerSettingsView: View {
    let tool: WindowManagerTool
    @State private var snapEnabled: Bool
    @State private var systemTiling: Bool

    init(tool: WindowManagerTool) {
        self.tool = tool
        _snapEnabled = State(initialValue: tool.snapEnabled)
        _systemTiling = State(initialValue: tool.systemEdgeTilingOn)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                PageHeader("Window Manager")

                SettingsSection("Snapping") {
                    SettingsRow(title: "Snap windows by dragging", detail: "Drag a window to an edge or corner of the screen.") {
                        Toggle("", isOn: snapBinding).toggleStyle(MonoToggleStyle()).labelsHidden()
                    }
                    if snapEnabled && systemTiling { systemTilingNote }
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
        .onAppear { systemTiling = tool.systemEdgeTilingOn }
    }

    /// macOS's own edge tiling fights drag-to-snap; point at the switch without nagging.
    private var systemTilingNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("macOS also tiles windows you drag to screen edges. Turn that off so they don't compete.")
                .font(Theme.Font.caption).foregroundStyle(Theme.fg(0.45))
                .fixedSize(horizontal: false, vertical: true)
            Button { Permissions.openSettings(.desktopAndDock) } label: {
                Text("Open Desktop & Dock").font(Theme.Font.caption).foregroundStyle(Theme.fg(0.7))
                    .underline().contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
        }
        .padding(.vertical, 11)
        .transition(.opacity)
    }

    /// The tool's own defaults are the single source of truth; the state only drives redraws.
    private var snapBinding: Binding<Bool> {
        Binding(get: { snapEnabled }, set: { snapEnabled = $0; tool.setSnapping($0) })
    }
}
