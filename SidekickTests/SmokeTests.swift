import Testing
@testable import Sidekick

struct SmokeTests {
    @Test func themeOpacityClamps() {
        #expect(Theme.clamp(2) == 1)
        #expect(Theme.clamp(-1) == 0)
        #expect(Theme.clamp(0.4) == 0.4)
    }
}
