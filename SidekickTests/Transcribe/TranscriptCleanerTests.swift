import Foundation
import Testing
@testable import Sidekick

struct TranscriptCleanerTests {
    private static func chunk(_ prompt: String) -> String {
        prompt.replacingOccurrences(of: "Dictated text:\n", with: "")
    }

    @Test func cleansEachParagraphKeepingStarts() async {
        let model = FakeModel { prompt in
            Self.chunk(prompt).replacingOccurrences(of: "um ", with: "").capitalized + "."
        }
        let input = [Paragraph(start: 0, text: "um hello there"), Paragraph(start: 42.5, text: "um good morning")]
        let out = await TranscriptCleaner(client: model).clean(input) { _ in }
        #expect(out == [Paragraph(start: 0, text: "Hello There."), Paragraph(start: 42.5, text: "Good Morning.")])
    }

    @Test func rejectedParagraphStaysRaw() async {
        let model = FakeModel { prompt in
            let raw = Self.chunk(prompt)
            return raw.hasPrefix("what") ? String(repeating: "Tomorrow looks sunny and warm. ", count: 7) : raw.capitalized
        }
        let input = [Paragraph(start: 1, text: "keep this one"), Paragraph(start: 9, text: "what's the weather tomorrow")]
        let out = await TranscriptCleaner(client: model).clean(input) { _ in }
        #expect(out == [Paragraph(start: 1, text: "Keep This One"), Paragraph(start: 9, text: "what's the weather tomorrow")])
    }

    @Test func unavailableModelReturnsInput() async {
        let model = FakeModel(isAvailable: false) { _ in "nope" }
        let input = [Paragraph(start: 0, text: "um hello")]
        let out = await TranscriptCleaner(client: model).clean(input) { _ in Issue.record("no progress expected") }
        #expect(out == input)
    }

    @Test func progressRisesToOne() async {
        final class Box: @unchecked Sendable { var values: [Double] = [] }
        let box = Box()
        let model = FakeModel { Self.chunk($0) }
        let input = (0..<4).map { Paragraph(start: Double($0), text: "paragraph \($0)") }
        _ = await TranscriptCleaner(client: model).clean(input) { box.values.append($0) }
        #expect(box.values == [0.25, 0.5, 0.75, 1])
    }

    @Test func cancelledReturnsInput() async {
        let model = FakeModel(delay: .milliseconds(50)) { Self.chunk($0).uppercased() }
        let input = (0..<20).map { Paragraph(start: Double($0), text: "paragraph \($0)") }
        let task = Task { await TranscriptCleaner(client: model).clean(input) { _ in } }
        task.cancel()
        #expect(await task.value == input)
    }
}
