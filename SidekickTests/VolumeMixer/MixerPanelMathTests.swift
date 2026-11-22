import AppKit
import CoreAudio
import Testing
@testable import Sidekick

struct MixerPanelMathTests {
    // MARK: Percent label

    @Test func percentRoundsToWholeNumbers() {
        #expect(MixerFormat.percent(0.7) == "70%")
        #expect(MixerFormat.percent(0.354) == "35%")
        #expect(MixerFormat.percent(0.356) == "36%")
        #expect(MixerFormat.percent(1) == "100%")
        #expect(MixerFormat.percent(0) == "0%")
    }

    @Test func percentClampsOutOfRange() {
        #expect(MixerFormat.percent(1.2) == "100%")
        #expect(MixerFormat.percent(-0.1) == "0%")
        #expect(MixerFormat.percent(.nan) == "0%")
    }

    // MARK: Slider mapping

    @Test func sliderMapsInsideTheKnobInset() {
        // 100 wide, 12pt knob: the usable track runs from x = 6 to x = 94.
        #expect(InkSliderMath.value(at: 6, width: 100, knob: 12) == 0)
        #expect(InkSliderMath.value(at: 94, width: 100, knob: 12) == 1)
        #expect(abs(InkSliderMath.value(at: 50, width: 100, knob: 12) - 0.5) < 1e-9)
    }

    @Test func sliderClampsPastTheEnds() {
        #expect(InkSliderMath.value(at: -40, width: 100, knob: 12) == 0)
        #expect(InkSliderMath.value(at: 400, width: 100, knob: 12) == 1)
    }

    @Test func sliderSurvivesADegenerateWidth() {
        #expect(InkSliderMath.value(at: 5, width: 10, knob: 12) == 0)
    }

    @Test func knobCentreRoundTrips() {
        let x = InkSliderMath.knobCenter(for: 0.25, width: 100, knob: 12)
        #expect(abs(x - 28) < 1e-9)
        #expect(abs(InkSliderMath.value(at: x, width: 100, knob: 12) - 0.25) < 1e-9)
    }

    // MARK: Level bars

    @Test func silenceLightsNothing() {
        #expect(LevelBarsMath.fills(level: 0) == [0, 0, 0])
    }

    @Test func fullScaleLightsEverything() {
        #expect(LevelBarsMath.fills(level: 1) == [1, 1, 1])
    }

    @Test func barsFillInOrder() {
        // −20 dBFS sits 30 dB above the −50 floor: 60% of the way, so bar 1 full, bar 2 at 0.8.
        let fills = LevelBarsMath.fills(level: 0.1)
        #expect(fills[0] == 1)
        #expect(abs(fills[1] - 0.8) < 1e-4)
        #expect(fills[2] == 0)
    }

    @Test func meterRisesAtOnceAndFallsSlowly() {
        #expect(LevelBarsMath.smoothed(previous: 0.1, next: 0.8) == 0.8)
        let fallen = LevelBarsMath.smoothed(previous: 0.8, next: 0)
        #expect(fallen < 0.8 && fallen > 0.3)
    }

    // MARK: Speaker glyph

    @Test func speakerGlyphFollowsVolumeAndMute() {
        #expect(SpeakerGlyph.name(volume: 0.8, muted: true) == "speaker.slash.fill")
        #expect(SpeakerGlyph.name(volume: 0, muted: false) == "speaker.fill")
        #expect(SpeakerGlyph.name(volume: 0.2, muted: false) == "speaker.wave.1.fill")
        #expect(SpeakerGlyph.name(volume: 0.5, muted: false) == "speaker.wave.2.fill")
        #expect(SpeakerGlyph.name(volume: 0.9, muted: false) == "speaker.wave.3.fill")
        #expect(SpeakerGlyph.name(volume: nil, muted: false) == "speaker.wave.2.fill")
    }

    // MARK: Panel position

    @Test func panelCentresUnderTheItem() {
        let origin = MixerPanelLayout.origin(item: NSRect(x: 900, y: 1092, width: 30, height: 24),
                                             size: NSSize(width: 340, height: 200),
                                             visible: NSRect(x: 0, y: 0, width: 1728, height: 1085))
        #expect(origin == NSPoint(x: 745, y: 885))
    }

    @Test func panelStaysOnScreenNearTheRightEdge() {
        let origin = MixerPanelLayout.origin(item: NSRect(x: 1700, y: 1092, width: 24, height: 24),
                                             size: NSSize(width: 340, height: 200),
                                             visible: NSRect(x: 0, y: 0, width: 1728, height: 1085))
        #expect(origin.x == 1388)
    }

    @Test func panelStaysOnASecondScreenToTheLeft() {
        let origin = MixerPanelLayout.origin(item: NSRect(x: -1900, y: 1092, width: 24, height: 24),
                                             size: NSSize(width: 340, height: 200),
                                             visible: NSRect(x: -1920, y: 0, width: 1920, height: 1055))
        #expect(origin.x == -1920)
        #expect(origin.y == 855)
    }

    // MARK: Held row

    private func row(_ id: String, _ name: String, volume: Double = 1) -> MixerRow {
        MixerRow(id: id, name: name, isPlaying: false, setting: AppVolume(volume: volume, muted: false),
                 playsElsewhere: false)
    }

    @Test func heldRowStaysWhileItsDragReturnsItToStandard() {
        let rows = [row("a", "Alpha", volume: 0.5), row("c", "Cello", volume: 0.5)]
        let held = row("b", "Bravo", volume: 0.9)
        #expect(MixerDisplay.rows(rows, holding: held).map(\.id) == ["a", "b", "c"])
    }

    @Test func liveRowWinsOverTheHeldCopy() {
        let rows = [row("a", "Alpha", volume: 0.3)]
        let shown = MixerDisplay.rows(rows, holding: row("a", "Alpha", volume: 0.9))
        #expect(shown == rows)
        #expect(MixerDisplay.rows(rows, holding: nil) == rows)
    }
}

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
