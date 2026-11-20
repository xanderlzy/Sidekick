import Testing
import Foundation
@testable import Sidekick

struct FormattingTests {
    @Test func durationFormatting() {
        #expect(Formatting.duration(0) == "0m")
        #expect(Formatting.duration(59) == "0m")
        #expect(Formatting.duration(300) == "5m")
        #expect(Formatting.duration(3 * 3600 + 12 * 60 + 30) == "3h 12m")
        #expect(Formatting.duration(2 * 3600) == "2h 0m")
    }

    @Test func wordCountUsesGrouping() {
        #expect(Formatting.count(0) == "0")
        #expect(Formatting.count(12_345) == "12,345")
    }

    @Test func dayLabels() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(Formatting.dayLabel(now, now: now, calendar: cal) == "Today")
        #expect(Formatting.dayLabel(now.addingTimeInterval(-86_400), now: now, calendar: cal) == "Yesterday")
        #expect(Formatting.dayLabel(now.addingTimeInterval(-5 * 86_400), now: now, calendar: cal) != "Yesterday")
    }

    @Test func groupsRecordsByDayNewestFirst() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let dates = [now, now.addingTimeInterval(-60), now.addingTimeInterval(-86_400)]
        let groups = Formatting.groupByDay(dates, calendar: cal) { $0 }
        #expect(groups.count == 2)
        #expect(groups[0].items.count == 2)
        #expect(groups[0].day > groups[1].day)
    }
}
