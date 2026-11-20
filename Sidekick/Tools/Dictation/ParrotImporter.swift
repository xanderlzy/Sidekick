import Foundation
import SwiftData

/// One-time import of a Parrot user's settings and history into Dictation.
/// Reads Parrot's data without ever modifying it: the store is copied as plain files and only the copy is opened.
@MainActor
struct ParrotImporter {
    static let parrotDomain = "com.parrot.app"
    static let importedKey = "parrotImported"
    static let countKey = "parrotImportCount"
    static let keys: [String] = [
        "hotkey", "inputDeviceUID", SystemSounds.enabledKey, RetentionPolicy.storageKey,
        TranscriberKind.storageKey, StatsStore.key, WhisperModelStore.pathKey,
    ]

    /// Suite lookups fall back to the app's own domain, so values are read from the persistent domain itself.
    let source: UserDefaults?
    let sourceDomain: String
    let destination: UserDefaults
    /// Directories holding `History.store` (and its `-shm` / `-wal` sidecars).
    let sourceStore: URL
    let destinationStore: URL

    init(source: UserDefaults?, sourceDomain: String = ParrotImporter.parrotDomain, destination: UserDefaults,
         sourceStore: URL, destinationStore: URL) {
        self.source = source
        self.sourceDomain = sourceDomain
        self.destination = destination
        self.sourceStore = sourceStore
        self.destinationStore = destinationStore
    }

    /// The real Parrot install.
    static func live(destination: UserDefaults = .standard) -> ParrotImporter {
        ParrotImporter(source: UserDefaults(suiteName: parrotDomain), destination: destination,
                       sourceStore: .applicationSupportDirectory.appending(path: "Parrot"),
                       destinationStore: .applicationSupportDirectory.appending(path: "Sidekick"))
    }

    /// Nil if already imported or there is no Parrot data; otherwise the number of imported dictations (0 if only settings).
    func importIfNeeded() throws -> Int? {
        guard !destination.bool(forKey: Self.importedKey) else { return nil }
        let fm = FileManager.default
        let sourceFile = sourceStore.appending(path: "History.store")
        let settings = source?.persistentDomain(forName: sourceDomain) ?? [:]
        let hasSettings = Self.keys.contains { settings[$0] != nil }
        let hasHistory = fm.fileExists(atPath: sourceFile.path)
        guard hasSettings || hasHistory else {
            destination.set(true, forKey: Self.importedKey)
            return nil
        }

        for key in Self.keys where destination.object(forKey: key) == nil {
            if let value = settings[key] { destination.set(value, forKey: key) }
        }

        var imported = 0
        let destinationFile = destinationStore.appending(path: "History.store")
        if hasHistory, !fm.fileExists(atPath: destinationFile.path) {
            imported = try copyStore()
        }
        destination.set(true, forKey: Self.importedKey)
        return imported
    }

    /// Stages the copy in a temporary directory, verifies it by opening it, then moves it into place,
    /// so a failure never leaves a partial store behind and the next launch can retry.
    private func copyStore() throws -> Int {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appending(path: "ParrotImport-\(UUID().uuidString)")
        var moved: [URL] = []
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            // Sidecars first, main file last, to narrow the window if Parrot is writing.
            for suffix in ["-wal", "-shm", ""] {
                let from = sourceStore.appending(path: "History.store" + suffix)
                guard fm.fileExists(atPath: from.path) else { continue }
                try fm.copyItem(at: from, to: staging.appending(path: "History.store" + suffix))
            }
            let count: Int
            do {
                let container = try HistoryStore.makeContainer(in: staging)
                count = try container.mainContext.fetchCount(FetchDescriptor<DictationRecord>())
            }
            try fm.createDirectory(at: destinationStore, withIntermediateDirectories: true)
            for name in try fm.contentsOfDirectory(atPath: staging.path) where name.hasPrefix("History.store") {
                let to = destinationStore.appending(path: name)
                try fm.moveItem(at: staging.appending(path: name), to: to)
                moved.append(to)
            }
            return count
        } catch {
            moved.forEach { try? fm.removeItem(at: $0) }
            throw error
        }
    }
}
