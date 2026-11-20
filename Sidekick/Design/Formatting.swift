import Foundation

enum Formatting {
    /// "3h 12m", "5m", "0m".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    static func count(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    static func dayLabel(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
            return "Yesterday"
        }
        var style = Date.FormatStyle(date: .complete, time: .omitted)
        style.timeZone = calendar.timeZone
        return date.formatted(style.weekday(.wide).month(.wide).day())
    }

    struct DayGroup<Item> {
        let day: Date
        let items: [Item]
    }

    /// Groups items by calendar day, newest day first, keeping item order within a day.
    static func groupByDay<Item>(_ items: [Item], calendar: Calendar = .current,
                                 date: (Item) -> Date) -> [DayGroup<Item>] {
        var order: [Date] = []
        var buckets: [Date: [Item]] = [:]
        for item in items {
            let day = calendar.startOfDay(for: date(item))
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(item)
        }
        return order.sorted(by: >).map { DayGroup(day: $0, items: buckets[$0]!) }
    }
}
