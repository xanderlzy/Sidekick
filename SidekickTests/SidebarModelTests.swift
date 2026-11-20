import Testing
@testable import Sidekick

@MainActor
struct SidebarModelTests {
    @Test func noToolsHasSingleDivider() {
        #expect(SidebarModel.items(for: []) == [
            .route(.home, title: "Home"), .divider, .route(.general, title: "General")])
    }

    @Test func singlePageToolIsOneRow() {
        let t = FakeTool(id: "keepOnTop", name: "Keep on Top", pageIDs: [("main", "Keep on Top")])
        #expect(SidebarModel.items(for: [t]) == [
            .route(.home, title: "Home"), .divider,
            .route(.page(tool: "keepOnTop", page: "main"), title: "Keep on Top"),
            .divider, .route(.general, title: "General")])
    }

    @Test func multiPageToolIsGroup() {
        let t = FakeTool(id: "dictation", name: "Dictation",
                         pageIDs: [("home", "Home"), ("history", "History"), ("settings", "Settings")])
        #expect(SidebarModel.items(for: [t]) == [
            .route(.home, title: "Home"), .divider,
            .group(title: "Dictation"),
            .route(.page(tool: "dictation", page: "home"), title: "Home"),
            .route(.page(tool: "dictation", page: "history"), title: "History"),
            .route(.page(tool: "dictation", page: "settings"), title: "Settings"),
            .divider, .route(.general, title: "General")])
    }

    @Test func disabledToolRouteFallsBackHome() {
        #expect(SidebarModel.validated(.page(tool: "dictation", page: "history"), tools: []) == .home)
    }

    @Test func enabledToolRouteIsKept() {
        let t = FakeTool(id: "dictation", pageIDs: [("history", "History")])
        let r = Route.page(tool: "dictation", page: "history")
        #expect(SidebarModel.validated(r, tools: [t]) == r)
        #expect(SidebarModel.validated(.general, tools: []) == .general)
    }
}
