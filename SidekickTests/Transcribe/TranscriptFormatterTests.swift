import Testing
@testable import Sidekick

struct TranscriptFormatterTests {
    private func words(_ n: Int) -> String {
        Array(repeating: "word", count: n).joined(separator: " ")
    }

    @Test func breaksOnPauseOverThreshold() {
        let s = [Segment(start: 0, end: 2, text: "One."), Segment(start: 2.5, end: 4, text: "Two."),
                 Segment(start: 6, end: 8, text: "Three.")]
        #expect(TranscriptFormatter.paragraphs(s) == [Paragraph(start: 0, text: "One. Two."), Paragraph(start: 6, text: "Three.")])
    }

    @Test func pauseExactlyAtThresholdDoesNotBreak() {
        let s = [Segment(start: 0, end: 2, text: "One."), Segment(start: 3.5, end: 4, text: "Two.")]
        #expect(TranscriptFormatter.paragraphs(s) == [Paragraph(start: 0, text: "One. Two.")])
    }

    @Test func breaksPastMaxWords() {
        let s = [Segment(start: 0, end: 10, text: words(50)),
                 Segment(start: 10, end: 20, text: words(50)),
                 Segment(start: 20, end: 30, text: words(50))]
        let p = TranscriptFormatter.paragraphs(s)
        #expect(p.count == 2)
        #expect(p[0] == Paragraph(start: 0, text: words(50) + " " + words(50)))
        #expect(p[1] == Paragraph(start: 20, text: words(50)))
    }

    @Test func overlongSingleSegmentStaysWhole() {
        let s = [Segment(start: 0, end: 10, text: words(150))]
        #expect(TranscriptFormatter.paragraphs(s) == [Paragraph(start: 0, text: words(150))])
    }

    @Test func timestampFormats() {
        #expect(TranscriptFormatter.timestamp(252) == "[04:12]")
        #expect(TranscriptFormatter.timestamp(252.9) == "[04:12]")
        #expect(TranscriptFormatter.timestamp(3599) == "[59:59]")
        #expect(TranscriptFormatter.timestamp(3600) == "[1:00:00]")
    }

    @Test func textWithAndWithoutTimestamps() {
        let p = [Paragraph(start: 0, text: "A."), Paragraph(start: 65, text: "B.")]
        #expect(TranscriptFormatter.text(p, timestamps: true) == "[00:00] A.\n\n[01:05] B.")
        #expect(TranscriptFormatter.text(p, timestamps: false) == "A.\n\nB.")
    }

    @Test func emptyTranscriptSaysNoSpeech() {
        #expect(TranscriptFormatter.text([], timestamps: true) == "No speech found in this file.")
        #expect(TranscriptFormatter.text([], timestamps: false) == "No speech found in this file.")
    }

    @Test func trimsAndSkipsBlankSegments() {
        let s = [Segment(start: 1, end: 2, text: "  Hello. "), Segment(start: 2, end: 3, text: "   "),
                 Segment(start: 3, end: 4, text: "World.")]
        #expect(TranscriptFormatter.paragraphs(s, pause: .infinity) == [Paragraph(start: 1, text: "Hello. World.")])
    }

    @Test func blankSegmentDoesNotResetPause() {
        let s = [Segment(start: 0, end: 2, text: "One."), Segment(start: 2, end: 10, text: " "),
                 Segment(start: 3, end: 4, text: "Two.")]
        #expect(TranscriptFormatter.paragraphs(s) == [Paragraph(start: 0, text: "One. Two.")])
    }
}
