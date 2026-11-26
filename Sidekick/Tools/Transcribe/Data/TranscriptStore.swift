import Foundation
import os
import SwiftData

/// Persists saved transcripts.
@MainActor
final class TranscriptStore {
    let container: ModelContainer
    private let log = Logger(subsystem: "com.sidekick.app", category: "Transcribe")
    private var context: ModelContext { container.mainContext }

    init(container: ModelContainer) {
        self.container = container
    }

    /// On-disk store at `Transcripts.store` inside `directory` (created if needed).
    static func makeContainer(in directory: URL) throws -> ModelContainer {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = ModelConfiguration(url: directory.appending(path: "Transcripts.store"))
        return try ModelContainer(for: Transcript.self, configurations: config)
    }

    @discardableResult
    func add(fileURL: URL, wantsCleanup: Bool) -> Transcript {
        let transcript = Transcript(title: fileURL.deletingPathExtension().lastPathComponent,
                                    fileURL: fileURL, wantsCleanup: wantsCleanup)
        context.insert(transcript)
        save()
        return transcript
    }

    func save() {
        do { try context.save() } catch { log.error("Save failed: \(error)") }
    }

    func delete(_ transcript: Transcript) {
        context.delete(transcript)
        save()
    }

    /// Jobs interrupted by a quit: in-progress ones become incomplete, queued ones stopped.
    /// A retry cut short keeps whichever run reaches further.
    func recoverAfterLaunch() {
        for t in all() {
            t.settleRetry()
            switch t.status {
            case .transcribing:
                t.status = .incomplete
                t.stoppedAt = t.segments.last?.end ?? 0
            case .waiting:
                t.status = .stopped
            default:
                break
            }
        }
        save()
    }

    /// Newest first.
    func all() -> [Transcript] {
        let descriptor = FetchDescriptor<Transcript>(sortBy: [SortDescriptor(\.dateAdded, order: .reverse)])
        do { return try context.fetch(descriptor) }
        catch {
            log.error("Fetch failed: \(error)")
            return []
        }
    }
}
