import CoreAudio
import Testing
@testable import Sidekick

struct SystemVolumeElementsTests {
    private let main = kAudioObjectPropertyElementMain

    @Test func mainElementWins() {
        #expect(SystemVolumeElements.select { _ in true } == [main])
    }

    @Test func fallsBackToBothChannels() {
        #expect(SystemVolumeElements.select { $0 != self.main } == [1, 2])
    }

    @Test func fallsBackToOneChannel() {
        #expect(SystemVolumeElements.select { $0 == 1 } == [1])
    }

    @Test func hiddenWhenNothingIsSettable() {
        #expect(SystemVolumeElements.select { _ in false }.isEmpty)
    }

    @Test func averageOfChannels() {
        #expect(SystemVolumeElements.average([0.25, 0.75]) == 0.5)
        #expect(SystemVolumeElements.average([]) == nil)
    }
}
