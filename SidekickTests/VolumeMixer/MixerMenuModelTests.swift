import Testing
@testable import Sidekick

struct MixerMenuHelperTests {
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

    // MARK: Speaker glyph

    @Test func speakerGlyphFollowsVolumeAndMute() {
        #expect(SpeakerGlyph.name(volume: 0.8, muted: true) == "speaker.slash.fill")
        #expect(SpeakerGlyph.name(volume: 0, muted: false) == "speaker.fill")
        #expect(SpeakerGlyph.name(volume: 0.2, muted: false) == "speaker.wave.1.fill")
        #expect(SpeakerGlyph.name(volume: 0.5, muted: false) == "speaker.wave.2.fill")
        #expect(SpeakerGlyph.name(volume: 0.9, muted: false) == "speaker.wave.3.fill")
        #expect(SpeakerGlyph.name(volume: nil, muted: false) == "speaker.wave.2.fill")
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

    @Test func heldCopyFollowsTheDragAndIsUnmuted() {
        let muted = MixerRow(id: "a", name: "Alpha", isPlaying: false, setting: AppVolume(volume: 0.4, muted: true),
                             playsElsewhere: false)
        let dragged = MixerDisplay.dragged(muted, to: 1)
        #expect(dragged.setting == AppVolume(volume: 1, muted: false))
        #expect(dragged.id == "a" && dragged.name == "Alpha")
    }

    @Test func liveRowWinsOverTheHeldCopy() {
        let rows = [row("a", "Alpha", volume: 0.3)]
        let shown = MixerDisplay.rows(rows, holding: row("a", "Alpha", volume: 0.9))
        #expect(shown == rows)
        #expect(MixerDisplay.rows(rows, holding: nil) == rows)
    }
}

struct MixerMenuModelTests {
    private func row(_ id: String, _ name: String, playing: Bool = true) -> MixerRow {
        MixerRow(id: id, name: name, isPlaying: playing, setting: AppVolume(volume: 0.7, muted: false),
                 playsElsewhere: false)
    }

    private var chrome: MixerRow { row("com.google.Chrome", "Google Chrome") }
    private var music: MixerRow { row("com.apple.Music", "Music") }

    @Test func normalLayout() {
        let entries = MixerMenuModel.entries(rows: [chrome, music], needsPermission: false, notice: nil,
                                             deviceName: "MacBook Pro Speakers")
        #expect(entries == [
            .header("Sound"), .system, .deviceCaption("MacBook Pro Speakers"), .separator,
            .sectionHeader("Apps"), .app(chrome), .app(music), .separator,
            .action("Volume Mixer Settings…"),
        ])
    }

    @Test func emptyShowsNothingPlaying() {
        let entries = MixerMenuModel.entries(rows: [], needsPermission: false, notice: nil,
                                             deviceName: "MacBook Pro Speakers")
        #expect(entries == [
            .header("Sound"), .system, .deviceCaption("MacBook Pro Speakers"), .separator,
            .sectionHeader("Apps"), .caption("Nothing's playing right now."), .separator,
            .action("Volume Mixer Settings…"),
        ])
    }

    @Test func needsPermissionReplacesApps() {
        let entries = MixerMenuModel.entries(rows: [chrome], needsPermission: true, notice: "Ignored",
                                             deviceName: "MacBook Pro Speakers")
        #expect(entries == [
            .header("Sound"), .system, .deviceCaption("MacBook Pro Speakers"), .separator,
            .sectionHeader("Apps"), .caption("Volume Mixer needs System Audio Recording"),
            .action("Open Settings…"), .separator, .action("Volume Mixer Settings…"),
        ])
    }

    @Test func noticeShownAsCaption() {
        let notice = "Couldn't keep Music's volume on this device"
        let entries = MixerMenuModel.entries(rows: [chrome, music], needsPermission: false, notice: notice,
                                             deviceName: "MacBook Pro Speakers")
        #expect(entries == [
            .header("Sound"), .system, .deviceCaption("MacBook Pro Speakers"), .separator,
            .sectionHeader("Apps"), .app(chrome), .app(music), .caption(notice), .separator,
            .action("Volume Mixer Settings…"),
        ])
    }

    @Test func noticeFollowsTheEmptyCaption() {
        let entries = MixerMenuModel.entries(rows: [], needsPermission: false, notice: "Note",
                                             deviceName: "Speakers")
        #expect(entries.suffix(4) == [.caption("Nothing's playing right now."), .caption("Note"), .separator,
                                      .action("Volume Mixer Settings…")])
    }

    @Test func noDeviceNameMeansNoCaption() {
        let entries = MixerMenuModel.entries(rows: [], needsPermission: false, notice: nil, deviceName: "")
        #expect(Array(entries.prefix(3)) == [.header("Sound"), .system, .separator])
    }

    // MARK: Icons

    @Test func webContentUsesTheGlobe() {
        let source = MixerAppIcon.source(for: AppGrouping.webContentKey, runningPath: { _ in "/x" },
                                         installedPath: { _ in "/y" })
        #expect(source == .globe)
    }

    @Test func iconComesFromTheRunningAppsOwnBundle() {
        let source = MixerAppIcon.source(for: "com.google.Chrome",
                                         runningPath: { $0 == "com.google.Chrome" ? "/Applications/Google Chrome.app" : nil },
                                         installedPath: { _ in "/Other/Google Chrome.app" })
        #expect(source == .file("/Applications/Google Chrome.app"))
    }

    @Test func iconFallsBackToTheInstalledApp() {
        let source = MixerAppIcon.source(for: "com.hnc.Discord", runningPath: { _ in nil },
                                         installedPath: { _ in "/Applications/Discord.app" })
        #expect(source == .file("/Applications/Discord.app"))
    }

    @Test func unknownAppHasNoIcon() {
        #expect(MixerAppIcon.source(for: "x.y", runningPath: { _ in nil }, installedPath: { _ in nil }) == .none)
    }
}
