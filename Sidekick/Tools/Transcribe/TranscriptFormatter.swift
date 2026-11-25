import Foundation

enum TranscriptFormatter {
    static let noSpeechText = "No speech found in this file."

    /// Groups segments into paragraphs. A gap strictly greater than `pause` seconds between
    /// segments, or a segment that would push a paragraph past `maxWords`, starts a new one.
    /// Blank segments are skipped and don't affect pause measurement.
    static func paragraphs(_ segments: [Segment], pause: Double = 1.5, maxWords: Int = 120) -> [Paragraph] {
        var result: [Paragraph] = []
        var start = 0.0
        var parts: [String] = []
        var wordCount = 0
        var lastEnd = 0.0

        func close() {
            guard !parts.isEmpty else { return }
            result.append(Paragraph(start: start, text: parts.joined(separator: " ")))
            parts = []
            wordCount = 0
        }

        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let words = text.split(whereSeparator: \.isWhitespace).count
            if !parts.isEmpty, segment.start - lastEnd > pause || wordCount + words > maxWords {
                close()
            }
            if parts.isEmpty { start = segment.start }
            parts.append(text)
            wordCount += words
            lastEnd = segment.end
        }
        close()
        return result
    }

    /// `[mm:ss]`, or `[h:mm:ss]` from one hour on. Fractional seconds are truncated.
    static func timestamp(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0
            ? String(format: "[%d:%02d:%02d]", h, m, s)
            : String(format: "[%02d:%02d]", m, s)
    }

    /// The text used for Copy and .txt export.
    static func text(_ paragraphs: [Paragraph], timestamps: Bool) -> String {
        guard !paragraphs.isEmpty else { return noSpeechText }
        return paragraphs
            .map { timestamps ? "\(timestamp($0.start)) \($0.text)" : $0.text }
            .joined(separator: "\n\n")
    }
}
