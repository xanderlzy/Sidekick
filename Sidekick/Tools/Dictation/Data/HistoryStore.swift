import Foundation
import SwiftData

/// Saves finished dictations (subject to the retention setting) and updates stats.
@MainActor
final class HistoryStore: DictationSink {
    let container: ModelContainer
    let stats: StatsStore
    private let policy: () -> RetentionPolicy
    private var context: ModelContext { container.mainContext }

    init(container: ModelContainer, stats: StatsStore, policy: @escaping () -> RetentionPolicy) {
        self.container = container
        self.stats = stats
        self.policy = policy
    }

    /// On-disk store at `History.store` inside `directory` (created if needed).
    static func makeContainer(in directory: URL) throws -> ModelContainer {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = ModelConfiguration(url: directory.appending(path: "History.store"))
        return try ModelContainer(for: DictationRecord.self, configurations: config)
    }

    func record(raw: String, final: String, duration: TimeInterval, appName: String?) {
        stats.add(words: Stats.wordCount(final), seconds: duration)
        guard policy().keepsNew else { return }
        context.insert(DictationRecord(rawText: raw, finalText: final, duration: duration, appName: appName))
        try? context.save()
    }

    func prune(now: Date = .now) {
        guard let cutoff = policy().cutoff(now: now) else { return }
        let old = (try? context.fetch(FetchDescriptor<DictationRecord>(predicate: #Predicate { $0.date < cutoff }))) ?? []
        old.forEach(context.delete)
        try? context.save()
    }

    func delete(_ record: DictationRecord) {
        context.delete(record)
        try? context.save()
    }

    func deleteAll() {
        ((try? context.fetch(FetchDescriptor<DictationRecord>())) ?? []).forEach(context.delete)
        try? context.save()
    }
}
