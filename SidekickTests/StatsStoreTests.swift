import Testing
import Foundation
@testable import Sidekick

struct StatsStoreTests {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    let today = Date(timeIntervalSince1970: 1_800_000_000)
    func day(_ offset: Int) -> Date { today.addingTimeInterval(Double(offset) * 86_400) }
    func stats(days: [Int]) -> Stats {
        Stats(totalWords: 0, speakingSeconds: 0, activeDays: Set(days.map { Stats.key(for: day($0), calendar: cal) }))
    }

    @Test func timeSavedMath() {
        #expect(Stats(totalWords: 400, speakingSeconds: 120, activeDays: []).timeSavedSeconds == 480)
    }
    @Test func timeSavedNeverNegative() {
        #expect(Stats(totalWords: 10, speakingSeconds: 600, activeDays: []).timeSavedSeconds == 0)
    }
    @Test func streakCountsBackFromToday() {
        #expect(stats(days: [0, -1, -2, -4]).streak(today: today, calendar: cal) == 3)
    }
    @Test func streakFromYesterdayIfNoneToday() {
        #expect(stats(days: [-1, -2]).streak(today: today, calendar: cal) == 2)
    }
    @Test func streakZeroWhenGap() {
        #expect(stats(days: [-2]).streak(today: today, calendar: cal) == 0)
    }
    @Test func statsPersistAcrossInstances() {
        let suite = "sidekick.test.\(UUID())"
        let a = StatsStore(defaults: UserDefaults(suiteName: suite)!)
        a.add(words: 12, seconds: 4, on: today)
        let b = StatsStore(defaults: UserDefaults(suiteName: suite)!)
        #expect(b.stats.totalWords == 12)
        #expect(b.stats.speakingSeconds == 4)
        #expect(b.stats.activeDays.count == 1)
    }
    @Test func wordCountSplitsOnWhitespace() {
        #expect(Stats.wordCount("  Hello,  there\nfriend. ") == 3)
    }
}
