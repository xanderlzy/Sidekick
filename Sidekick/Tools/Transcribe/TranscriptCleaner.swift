import Foundation

/// Optional light cleanup of a finished transcript, one paragraph at a time, with the same
/// on-device model and safety checks Dictation uses. Paragraph start times are kept.
struct TranscriptCleaner {
    let client: LanguageModelClient

    init(client: LanguageModelClient) {
        self.client = client
    }

    /// Returns the input unchanged if the model is unavailable or the task is cancelled
    /// (paragraphs finished before the cancel are discarded). A paragraph the model mangles stays raw.
    func clean(_ paragraphs: [Paragraph], onProgress: @Sendable (Double) -> Void) async -> [Paragraph] {
        guard client.isAvailable, !paragraphs.isEmpty else { return paragraphs }
        // Each paragraph keeps the per-chunk timeout; the whole-dictation budget doesn't apply to a lecture.
        let polisher = FoundationPolisher(client: client, totalBudget: .seconds(86_400))
        var result: [Paragraph] = []
        result.reserveCapacity(paragraphs.count)
        for (i, paragraph) in paragraphs.enumerated() {
            if Task.isCancelled { return paragraphs }
            let outcome = await polisher.polish(paragraph.text)
            if Task.isCancelled { return paragraphs }
            result.append(Paragraph(start: paragraph.start, text: outcome.text))
            onProgress(Double(i + 1) / Double(paragraphs.count))
        }
        return result
    }
}
