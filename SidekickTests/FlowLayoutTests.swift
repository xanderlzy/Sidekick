import CoreGraphics
import Testing
@testable import Sidekick

struct FlowLayoutTests {
    private let chip = CGSize(width: 80, height: 20)

    @Test func itemsThatFitShareALine() {
        let f = FlowLayout.frames(for: [chip, chip, chip], width: 300, spacing: 6, lineSpacing: 6)
        #expect(f.map(\.minY) == [0, 0, 0])
        #expect(f.map(\.minX) == [0, 86, 172])
    }

    @Test func overflowingItemWrapsWhole() {
        let f = FlowLayout.frames(for: [chip, chip, chip], width: 200, spacing: 6, lineSpacing: 6)
        #expect(f[2].origin == CGPoint(x: 0, y: 26))
        #expect(f.allSatisfy { $0.size == chip })
    }

    @Test func itemWiderThanLineKeepsItsSize() {
        let wide = CGSize(width: 250, height: 20)
        let f = FlowLayout.frames(for: [wide, chip], width: 200, spacing: 6, lineSpacing: 6)
        #expect(f[0] == CGRect(origin: .zero, size: wide))
        #expect(f[1].minY == 26)
    }
}
