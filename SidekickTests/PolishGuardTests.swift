import Testing
@testable import Sidekick

struct PolishGuardTests {
    private func normalized(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private var sixHundredWords: String {
        (0..<30).map { i in
            (0..<19).map { "word\(i)x\($0)" }.joined(separator: " ") + " end."
        }.joined(separator: " ")
    }

    @Test func chunksSplitAtSentenceBoundaries() {
        let chunks = PolishGuard.chunks(sixHundredWords, maxWords: 250)
        #expect(chunks.count >= 3)
        for c in chunks {
            #expect(c.split(whereSeparator: \.isWhitespace).count <= 250)
            #expect(c.hasSuffix("."))
        }
    }

    @Test func longInputIsChunkedAndFullyPreserved() {
        let chunks = PolishGuard.chunks(sixHundredWords, maxWords: 250)
        #expect(normalized(chunks.joined(separator: " ")) == normalized(sixHundredWords))
    }

    @Test func runOnSentenceSplitsAtWords() {
        let text = (0..<600).map { "w\($0)" }.joined(separator: " ")
        let chunks = PolishGuard.chunks(text, maxWords: 250)
        #expect(chunks.map { $0.split(separator: " ").count } == [250, 250, 100])
        #expect(normalized(chunks.joined(separator: " ")) == text)
    }

    @Test func shortTextIsOneChunk() {
        #expect(PolishGuard.chunks("Hello there.") == ["Hello there."])
    }

    @Test func acceptRejectsEmptyAndRunaway() {
        #expect(!PolishGuard.accept(raw: "hi there", polished: "   "))
        #expect(!PolishGuard.accept(raw: "what's the weather tomorrow",
                                    polished: String(repeating: "It will be sunny. ", count: 12)))
        #expect(PolishGuard.accept(raw: "um so I think we should uh meet", polished: "I think we should meet."))
    }

    @Test func rejectsRefusalsAndAssistantReplies() {
        #expect(!PolishGuard.accept(raw: "what's the weather tomorrow", polished: "I'm sorry, I can't check the weather."))
        #expect(!PolishGuard.accept(raw: "send it to mark", polished: "Sure! Here's the message."))
        #expect(PolishGuard.accept(raw: "sure thing see you then", polished: "Sure thing, see you then."))
    }

    @Test func rejectsSummariesThatDropMostWords() {
        let raw = "so the plan for next week is that we finish the onboarding screens on monday then we test the pill on tuesday and wednesday and ship to friends on friday afternoon"
        #expect(!PolishGuard.accept(raw: raw, polished: "We'll ship on Friday."))
    }

    @Test func rejectsOutputUnrelatedToInput() {
        #expect(!PolishGuard.accept(raw: "write a poem about the ocean waves",
                                    polished: "Waves crash softly, blue and deep, secrets kept."))
    }

    @Test func acceptsRealCleanups() {
        #expect(PolishGuard.accept(raw: "okay so uh the meeting is at three no sorry four pm and you know bring the slides",
                                   polished: "Okay, the meeting is at four p.m. Bring the slides."))
        #expect(PolishGuard.accept(raw: "hey jess um just wanted to say thanks for yesterday it was it was really fun",
                                   polished: "Hey Jess, I just wanted to say thanks for yesterday. It was really fun."))
        #expect(PolishGuard.accept(raw: "um uh yeah", polished: "Yeah."))
    }
}
