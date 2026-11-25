import Foundation
import SwiftData

struct Segment: Codable, Hashable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

struct Paragraph: Codable, Hashable, Sendable {
    var start: Double
    var text: String
}

enum TranscriptStatus: String, Codable {
    case waiting, transcribing, done, incomplete, stopped, failed
}

@Model
final class Transcript {
    var id: UUID
    var title: String
    var fileURL: URL
    var dateAdded: Date
    /// Queue-order key; Retry bumps it.
    var queuedAt: Date
    var duration: Double
    /// `TranscriberKind` raw value, set when the job starts.
    var engine: String?
    /// Snapshot of the cleanup setting taken at queue time.
    var wantsCleanup: Bool
    var statusRaw: String
    var stoppedAt: Double?
    var failureReason: String?
    var segmentsData: Data
    var cleanedData: Data?

    init(id: UUID = UUID(), title: String, fileURL: URL, dateAdded: Date = .now,
         wantsCleanup: Bool, duration: Double = 0) {
        self.id = id
        self.title = title
        self.fileURL = fileURL
        self.dateAdded = dateAdded
        self.queuedAt = dateAdded
        self.duration = duration
        self.wantsCleanup = wantsCleanup
        self.statusRaw = TranscriptStatus.waiting.rawValue
        self.segmentsData = (try? JSONEncoder().encode([Segment]())) ?? Data()
    }

    var status: TranscriptStatus {
        get { TranscriptStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    var segments: [Segment] {
        get { (try? JSONDecoder().decode([Segment].self, from: segmentsData)) ?? [] }
        set { segmentsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var cleaned: [Paragraph]? {
        get { cleanedData.flatMap { try? JSONDecoder().decode([Paragraph].self, from: $0) } }
        set { cleanedData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
}
