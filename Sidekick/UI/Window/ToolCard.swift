import SwiftUI

/// One tool with its switch: icon, name and switch on one line; summary and permission chips below,
/// indented under the name. Used by Home and the setup tool picker so both look the same.
struct ToolCard: View {
    let tool: any Tool
    @Binding var isOn: Bool
    var showsPermissions = true

    private static let iconSize: CGFloat = 28
    private static let gap: CGFloat = 12
    /// Toggle width plus its gap, so copy never runs under the switch.
    private static let toggleColumn: CGFloat = 46

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            HStack(alignment: .center, spacing: Self.gap) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 18))
                    .frame(width: Self.iconSize, height: Self.iconSize)
                Text(tool.name).font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 12)
                Toggle("", isOn: $isOn).toggleStyle(MonoToggleStyle()).labelsHidden().fixedSize()
            }
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                Text(tool.summary)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.fg(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                if showsPermissions && !tool.permissions.isEmpty {
                    FlowLayout(spacing: Theme.Space.tight, lineSpacing: Theme.Space.tight) {
                        ForEach(tool.permissions, id: \.self) { Chip(text: $0.title) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Self.iconSize + Self.gap)
            .padding(.trailing, Self.toggleColumn)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
            .strokeBorder(Theme.fg(0.12), lineWidth: 1))
    }
}
