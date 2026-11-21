import Testing
import ApplicationServices
@testable import Sidekick

struct AXWindowTests {
    @Test func keyEqualityForSameElement() {
        let a = AXElementKey(AXUIElementCreateApplication(getpid()))
        let b = AXElementKey(AXUIElementCreateApplication(getpid()))
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }
}
