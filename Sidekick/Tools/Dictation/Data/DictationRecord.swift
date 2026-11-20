import Foundation
import SwiftData

@Model
final class DictationRecord {
    var id: UUID
    var date: Date
    var rawText: String
    var finalText: String
    var duration: TimeInterval
    var appName: String?

    init(id: UUID = UUID(), date: Date = .now, rawText: String, finalText: String,
         duration: TimeInterval, appName: String?) {
        self.id = id
        self.date = date
        self.rawText = rawText
        self.finalText = finalText
        self.duration = duration
        self.appName = appName
    }
}
