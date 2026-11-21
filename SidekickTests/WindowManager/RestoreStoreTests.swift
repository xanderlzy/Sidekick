import Testing
import CoreGraphics
@testable import Sidekick

struct RestoreStoreTests {
    let a = CGRect(x: 1, y: 2, width: 3, height: 4)
    let b = CGRect(x: 5, y: 6, width: 7, height: 8)

    @Test func rememberOnlyFirst() {
        var s = RestoreStore()
        s.rememberIfNeeded(a, for: 1)
        s.rememberIfNeeded(b, for: 1)
        #expect(s.original(for: 1) == a)
    }

    @Test func takeForgets() {
        var s = RestoreStore()
        s.rememberIfNeeded(a, for: 1)
        #expect(s.take(for: 1) == a)
        #expect(s.take(for: 1) == nil)
    }

    @Test func evictsOldestPast100() {
        var s = RestoreStore()
        for i in 0..<101 { s.rememberIfNeeded(a, for: i) }
        #expect(s.original(for: 0) == nil)
        #expect(s.original(for: 1) == a)
        #expect(s.original(for: 100) == a)
    }
}
