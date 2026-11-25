import Foundation
import SwiftData

/// Persists saved transcripts.
@MainActor
final class TranscriptStore {
    let container: ModelContainer
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
        try? context.save()
    }

    func delete(_ transcript: Transcript) {
        context.delete(transcript)
        save()
    }

    /// Jobs interrupted by a quit: in-progress ones become incomplete, queued ones stopped.
    func recoverAfterLaunch() {
        for t in all() {
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
        return (try? context.fetch(descriptor)) ?? []
    }
}
