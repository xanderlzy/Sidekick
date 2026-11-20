import Foundation
import SwiftData
import Testing
@testable import Sidekick

@MainActor
struct ParrotImporterTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "ParrotImporterTests-\(UUID())")
    let sourceSuite = "ParrotImporterTests-src-\(UUID())"
    let destSuite = "ParrotImporterTests-dst-\(UUID())"
    let source: UserDefaults
    let destination: UserDefaults
    var sourceStore: URL { root.appending(path: "Parrot") }
    var destinationStore: URL { root.appending(path: "Sidekick") }

    init() {
        source = UserDefaults(suiteName: sourceSuite)!
        destination = UserDefaults(suiteName: destSuite)!
    }

    private func cleanUp() {
        UserDefaults().removePersistentDomain(forName: sourceSuite)
        UserDefaults().removePersistentDomain(forName: destSuite)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(in directory: URL, records: Int) throws {
        let container = try HistoryStore.makeContainer(in: directory)
        for i in 0..<records {
            container.mainContext.insert(DictationRecord(rawText: "raw \(i)", finalText: "final \(i)", duration: 1, appName: nil))
        }
        try container.mainContext.save()
    }

    private func count(in directory: URL) throws -> Int {
        let container = try HistoryStore.makeContainer(in: directory)
        return try container.mainContext.fetchCount(FetchDescriptor<DictationRecord>())
    }

    private func importer() -> ParrotImporter {
        ParrotImporter(source: source, sourceDomain: sourceSuite, destination: destination, sourceStore: sourceStore, destinationStore: destinationStore)
    }

    private func seedParrot() throws {
        source.set("rightOption", forKey: "hotkey")
        source.set("mic-1", forKey: "inputDeviceUID")
        try makeStore(in: sourceStore, records: 3)
    }

    @Test func importsSettingsAndHistory() throws {
        defer { cleanUp() }
        try seedParrot()
        #expect(try importer().importIfNeeded() == 3)
        #expect(destination.string(forKey: "hotkey") == "rightOption")
        #expect(destination.string(forKey: "inputDeviceUID") == "mic-1")
        #expect(try count(in: destinationStore) == 3)
    }

    @Test func secondRunIsNoop() throws {
        defer { cleanUp() }
        try seedParrot()
        #expect(try importer().importIfNeeded() == 3)
        #expect(try importer().importIfNeeded() == nil)
        #expect(try count(in: destinationStore) == 3)
    }

    @Test func noParrotDataReturnsNilAndSetsFlag() throws {
        defer { cleanUp() }
        #expect(try importer().importIfNeeded() == nil)
        #expect(destination.bool(forKey: "parrotImported"))
        #expect(!FileManager.default.fileExists(atPath: destinationStore.appending(path: "History.store").path))
    }

    @Test func nilSourceReturnsNil() throws {
        defer { cleanUp() }
        let importer = ParrotImporter(source: nil, destination: destination, sourceStore: sourceStore, destinationStore: destinationStore)
        #expect(try importer.importIfNeeded() == nil)
    }

    @Test func settingsOnlyReturnsZero() throws {
        defer { cleanUp() }
        source.set("rightOption", forKey: "hotkey")
        #expect(try importer().importIfNeeded() == 0)
        #expect(destination.string(forKey: "hotkey") == "rightOption")
    }

    @Test func doesNotOverwriteExistingSidekickHistory() throws {
        defer { cleanUp() }
        try seedParrot()
        try makeStore(in: destinationStore, records: 1)
        #expect(try importer().importIfNeeded() == 0)
        #expect(try count(in: destinationStore) == 1)
        #expect(destination.string(forKey: "hotkey") == "rightOption")
    }

    @Test func doesNotOverwriteExistingSetting() throws {
        defer { cleanUp() }
        try seedParrot()
        destination.set("fn", forKey: "hotkey")
        _ = try importer().importIfNeeded()
        #expect(destination.string(forKey: "hotkey") == "fn")
        #expect(destination.string(forKey: "inputDeviceUID") == "mic-1")
    }

    @Test func neverModifiesSource() throws {
        defer { cleanUp() }
        try seedParrot()
        func dates() throws -> [String: Date] {
            let names = try FileManager.default.contentsOfDirectory(atPath: sourceStore.path).sorted()
            return try Dictionary(uniqueKeysWithValues: names.map {
                ($0, try FileManager.default.attributesOfItem(atPath: sourceStore.appending(path: $0).path)[.modificationDate] as! Date)
            })
        }
        let before = try dates()
        let hotkeyBefore = source.string(forKey: "hotkey")
        _ = try importer().importIfNeeded()
        #expect(try dates() == before)
        #expect(source.string(forKey: "hotkey") == hotkeyBefore)
        #expect(source.string(forKey: "parrotImported") == nil)
    }

    @Test func toolStartImportsOnceAndStoresCount() throws {
        defer { cleanUp() }
        try seedParrot()
        let tool = DictationTool(defaults: destination, startServices: false, storeDirectory: destinationStore, importer: importer())
        tool.start()
        #expect(destination.integer(forKey: ParrotImporter.countKey) == 3)
        #expect(try tool.env?.history.container.mainContext.fetchCount(FetchDescriptor<DictationRecord>()) == 3)
    }

    @Test func failedImportLeavesNoStoreAndRetrySucceeds() throws {
        defer { cleanUp() }
        try seedParrot()
        let file = sourceStore.appending(path: "History.store")
        let good = try Data(contentsOf: file)
        try Data("not a database".utf8).write(to: file)
        #expect(throws: (any Error).self) { try importer().importIfNeeded() }
        #expect(!FileManager.default.fileExists(atPath: destinationStore.appending(path: "History.store").path))
        #expect(!destination.bool(forKey: "parrotImported"))
        try good.write(to: file)
        #expect(try importer().importIfNeeded() == 3)
        #expect(try count(in: destinationStore) == 3)
    }

    @Test func happyPathLeavesNoStagingDirectory() throws {
        defer { cleanUp() }
        try seedParrot()
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("ParrotImport-") })
        _ = try importer().importIfNeeded()
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("ParrotImport-") })
        #expect(after.subtracting(before).isEmpty)
    }
}
