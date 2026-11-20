import SwiftUI

enum Route: Hashable {
    case home, general
    case page(tool: String, page: String)
}

enum SidebarItem: Equatable {
    case route(Route, title: String)
    case group(title: String)
    case divider
}

extension SidebarItem {
    /// Stable across enabling and disabling tools. Dividers have no payload, so
    /// `SidebarModel.identified` numbers them by position.
    var stableID: String? {
        switch self {
        case let .route(route, _): "route:\(route)"
        case let .group(title): "group:\(title)"
        case .divider: nil
        }
    }
}

enum SidebarModel {
    /// Pairs each item with an identity that survives tool changes: the Home divider is
    /// always "divider.0", and the divider before General is "divider.1".
    static func identified(_ items: [SidebarItem]) -> [(id: String, item: SidebarItem)] {
        var dividers = 0
        return items.map { item in
            if let id = item.stableID { return (id, item) }
            defer { dividers += 1 }
            return ("divider.\(dividers)", item)
        }
    }

    /// Home, enabled tools, General. Dividers only separate non-empty sections.
    @MainActor
    static func items(for tools: [any Tool]) -> [SidebarItem] {
        var items: [SidebarItem] = [.route(.home, title: "Home"), .divider]
        for tool in tools {
            if tool.pages.count == 1, let page = tool.pages.first {
                items.append(.route(.page(tool: tool.id, page: page.id), title: tool.name))
            } else if !tool.pages.isEmpty {
                items.append(.group(title: tool.name))
                items += tool.pages.map { .route(.page(tool: tool.id, page: $0.id), title: $0.title) }
            }
        }
        if !tools.isEmpty { items.append(.divider) }
        items.append(.route(.general, title: "General"))
        return items
    }

    /// A route to a tool that isn't enabled (or a page it doesn't have) falls back to Home.
    @MainActor
    static func validated(_ route: Route, tools: [any Tool]) -> Route {
        guard case let .page(toolID, pageID) = route else { return route }
        let exists = tools.contains { $0.id == toolID && $0.pages.contains { $0.id == pageID } }
        return exists ? route : .home
    }
}

struct Sidebar: View {
    let items: [SidebarItem]
    @Bindable var navigation: AppNavigation
    @Namespace private var indicator

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SidekickMark().padding(.bottom, 28)
            ForEach(SidebarModel.identified(items), id: \.id) { entry in
                Group {
                    switch entry.item {
                    case let .route(route, title): row(route, title, indented: isIndented(route))
                    case let .group(title): SectionLabel(text: title).padding(.top, 8).padding(.bottom, 2)
                    case .divider: Hairline().padding(.vertical, 8)
                    }
                }
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
            Spacer()
            Text("v\(Bundle.main.shortVersion)")
                .font(Theme.Font.caption).foregroundStyle(Theme.fg(0.3))
        }
        .padding(.top, 56).padding(.horizontal, 24).padding(.bottom, 24)
        .frame(width: 176, alignment: .leading)
    }

    /// Page rows that follow a group label are indented under it.
    private func isIndented(_ route: Route) -> Bool {
        guard case let .page(tool, _) = route else { return false }
        let siblings = items.filter {
            if case let .route(.page(t, _), _) = $0 { return t == tool }
            return false
        }
        return siblings.count > 1
    }

    private func row(_ route: Route, _ title: String, indented: Bool) -> some View {
        let selected = navigation.route == route
        return Button { navigation.route = route } label: {
            HStack(spacing: 10) {
                ZStack {
                    if selected {
                        Capsule().fill(Theme.fg()).frame(width: 2, height: 14)
                            .matchedGeometryEffect(id: "indicator", in: indicator)
                    }
                }
                .frame(width: 2)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(Theme.fg(selected ? 1 : 0.45))
            }
            .padding(.leading, indented ? 10 : 0)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
