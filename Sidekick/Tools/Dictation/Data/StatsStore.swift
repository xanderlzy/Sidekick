import Foundation
import Observation

struct Stats: Codable, Equatable, Sendable {
    var totalWords: Int
    var speakingSeconds: Double
    /// Days with at least one dictation, as "yyyy-MM-dd".
    var activeDays: Set<String>

    static let zero = Stats(totalWords: 0, speakingSeconds: 0, activeDays: [])
    static let typingWordsPerMinute = 40.0

    /// Time it would have taken to type the words, minus the time spent speaking them.
    var timeSavedSeconds: Double {
        max(0, Double(totalWords) / Self.typingWordsPerMinute * 60 - speakingSeconds)
    }

    /// Consecutive active days ending today (or yesterday, if nothing yet today).
    func streak(today: Date = .now, calendar: Calendar = .current) -> Int {
        var day = today
        if !activeDays.contains(Self.key(for: day, calendar: calendar)) {
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        var count = 0
        while activeDays.contains(Self.key(for: day, calendar: calendar)) {
            count += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return count
    }

    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

/// Running totals kept separately from history, so they survive pruning.
@Observable
final class StatsStore {
    static let key = "stats.v1"
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var stats: Stats

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        stats = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Stats.self, from: $0) } ?? .zero
    }

    func add(words: Int, seconds: Double, on date: Date = .now) {
        stats.totalWords += words
        stats.speakingSeconds += seconds
        stats.activeDays.insert(Stats.key(for: date))
        save()
    }

    func reset() { stats = .zero; save() }

    private func save() {
        if let data = try? JSONEncoder().encode(stats) { defaults.set(data, forKey: Self.key) }
    }
}
