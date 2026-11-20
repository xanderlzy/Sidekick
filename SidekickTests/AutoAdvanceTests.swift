import Testing
@testable import Sidekick

@MainActor
struct AutoAdvanceTests {
    @Test func schedulingTwiceFiresOnce() async throws {
        let auto = AutoAdvance()
        var fired = 0
        auto.schedule(after: .milliseconds(20)) { fired += 1 }
        auto.schedule(after: .milliseconds(20)) { fired += 1 }
        try await Task.sleep(for: .milliseconds(120))
        #expect(fired == 1)
    }

    @Test func cancelPreventsFiring() async throws {
        let auto = AutoAdvance()
        var fired = 0
        auto.schedule(after: .milliseconds(30)) { fired += 1 }
        auto.cancel()
        try await Task.sleep(for: .milliseconds(120))
        #expect(fired == 0)
    }
}
