import Foundation
import os
import SwiftData

private let log = Logger(subsystem: "com.sidekick.app", category: "Transcribe")

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

    /// Decoded segments. Returns `[]` if the stored data is unreadable; the setter then
    /// refuses to overwrite it, so a bad read can never wipe saved text.
    var segments: [Segment] {
        get { (try? JSONDecoder().decode([Segment].self, from: segmentsData)) ?? [] }
        set {
            guard (try? JSONDecoder().decode([Segment].self, from: segmentsData)) != nil else {
                log.error("Refusing to overwrite unreadable segments for \(self.id)")
                return
            }
            do { segmentsData = try JSONEncoder().encode(newValue) }
            catch { log.error("Failed to encode segments, keeping old data: \(error)") }
        }
    }

    var cleaned: [Paragraph]? {
        get { cleanedData.flatMap { try? JSONDecoder().decode([Paragraph].self, from: $0) } }
        set {
            guard let newValue else { cleanedData = nil; return }
            if let old = cleanedData, (try? JSONDecoder().decode([Paragraph].self, from: old)) == nil {
                log.error("Refusing to overwrite unreadable cleaned text for \(self.id)")
                return
            }
            do { cleanedData = try JSONEncoder().encode(newValue) }
            catch { log.error("Failed to encode cleaned text, keeping old data: \(error)") }
        }
    }
}
