import Foundation

/// Pure helpers that keep the on-device model honest: split long dictation into
/// model-sized pieces, and reject output that isn't a cleanup of the input.
enum PolishGuard {
    static func chunks(_ text: String, maxWords: Int = 250) -> [String] {
        var chunks: [String] = []
        var current: [String] = []
        func flush() {
            if !current.isEmpty { chunks.append(current.joined(separator: " ")); current = [] }
        }
        for sentence in sentences(text) {
            let words = sentence.split(whereSeparator: \.isWhitespace).map(String.init)
            if words.count > maxWords {
                flush()
                for start in stride(from: 0, to: words.count, by: maxWords) {
                    chunks.append(words[start..<min(start + maxWords, words.count)].joined(separator: " "))
                }
                continue
            }
            if current.count + words.count > maxWords { flush() }
            current.append(contentsOf: words)
        }
        flush()
        return chunks
    }

    /// Sentences ending in . ! or ? (punctuation kept); a trailing fragment counts as a sentence.
    private static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            let next = i + 1 < chars.count ? chars[i + 1] : " "
            if ".!?".contains(ch), next.isWhitespace {
                result.append(current); current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(current) }
        return result
    }

    /// Openings that mean the model replied to the text instead of cleaning it.
    static let assistantOpenings: [[String]] = [
        ["im", "sorry"], ["i", "cant"], ["i", "cannot"], ["sorry"], ["sure"], ["certainly"],
        ["as", "an", "ai"], ["here", "is"], ["heres"],
    ]

    static func accept(raw: String, polished: String) -> Bool {
        let trimmed = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Int(Double(raw.count) * 1.3) + 20 else { return false }
        let inWords = words(raw), outWords = words(trimmed)
        // A reply, not a cleanup — unless the speaker actually started that way.
        for opening in assistantOpenings where outWords.starts(with: opening) && !inWords.starts(with: opening) {
            return false
        }
        // Cleanup drops fillers and repeats, not most of what was said.
        if inWords.count >= 8, Double(outWords.count) < Double(inWords.count) * 0.4 { return false }
        // Cleanup reuses the speaker's words.
        if outWords.count >= 4 {
            let vocabulary = Set(inWords)
            let reused = outWords.filter(vocabulary.contains).count
            if Double(reused) < Double(outWords.count) * 0.6 { return false }
        }
        return true
    }

    /// Lowercased words with punctuation and apostrophes removed.
    static func words(_ s: String) -> [String] {
        s.lowercased()
            .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
