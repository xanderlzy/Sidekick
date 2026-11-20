import Testing
import Foundation
import SwiftData
@testable import Sidekick

@MainActor
struct RetentionPolicyTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func thirtyDayCutoff() {
        #expect(RetentionPolicy.thirtyDays.cutoff(now: now) == now.addingTimeInterval(-30 * 86_400))
        #expect(RetentionPolicy.sevenDays.cutoff(now: now) == now.addingTimeInterval(-7 * 86_400))
        #expect(RetentionPolicy.thirtyDays.keepsNew)
    }

    @Test func offDropsEverything() {
        #expect(RetentionPolicy.off.cutoff(now: now) == .distantFuture)
        #expect(!RetentionPolicy.off.keepsNew)
    }

    @Test func foreverKeepsAll() {
        #expect(RetentionPolicy.forever.cutoff(now: now) == nil)
    }

    @Test func defaultIsThirtyDays() {
        #expect(RetentionPolicy.default == .thirtyDays)
    }

    // HistoryStore against an in-memory SwiftData container.
    func store(policy: RetentionPolicy) throws -> (HistoryStore, StatsStore, ModelContainer) {
        let container = try ModelContainer(for: DictationRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let stats = StatsStore(defaults: UserDefaults(suiteName: "sidekick.test.\(UUID())")!)
        return (HistoryStore(container: container, stats: stats, policy: { policy }), stats, container)
    }

    @Test func recordSavesAndCountsStats() throws {
        let (history, stats, container) = try store(policy: .thirtyDays)
        history.record(raw: "hello there friend", final: "Hello there, friend.", duration: 2, appName: "Notes")
        let rows = try container.mainContext.fetch(FetchDescriptor<DictationRecord>())
        #expect(rows.count == 1)
        #expect(rows.first?.finalText == "Hello there, friend.")
        #expect(stats.stats.totalWords == 3)
    }

    @Test func offRecordsStatsButNotHistory() throws {
        let (history, stats, container) = try store(policy: .off)
        history.record(raw: "a b", final: "A b.", duration: 1, appName: nil)
        #expect(try container.mainContext.fetch(FetchDescriptor<DictationRecord>()).isEmpty)
        #expect(stats.stats.totalWords == 2)
    }

    @Test func pruneRemovesOldRows() throws {
        let (history, _, container) = try store(policy: .sevenDays)
        let ctx = container.mainContext
        ctx.insert(DictationRecord(date: now.addingTimeInterval(-8 * 86_400), rawText: "old", finalText: "Old.", duration: 1, appName: nil))
        ctx.insert(DictationRecord(date: now.addingTimeInterval(-1 * 86_400), rawText: "new", finalText: "New.", duration: 1, appName: nil))
        history.prune(now: now)
        let rows = try ctx.fetch(FetchDescriptor<DictationRecord>())
        #expect(rows.map(\.rawText) == ["new"])
    }
}
