import AppKit
import SwiftUI

// MARK: - Panel

/// The borderless, non-activating panel that hosts the mixer under its status item.
/// It becomes key without activating Sidekick (like Spotlight or Control Center): the frontmost app stays
/// active, and key returns to its window when the panel orders out. It floats on every Space and over full screen.
final class MixerPanel: NSPanel {
    /// The card's width; the window adds transparent margins around it for the shadow.
    static let cardWidth: CGFloat = 320
    static let margin = NSEdgeInsets(top: 6, left: 16, bottom: 28, right: 16)

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.cardWidth + Self.margin.left + Self.margin.right,
                                       height: 240),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false // the card draws its own, so it scales with the open animation
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The window size for a card of `card` size.
    static func windowSize(for card: CGSize) -> NSSize {
        NSSize(width: card.width + margin.left + margin.right, height: card.height + margin.top + margin.bottom)
    }
}

/// A hosting view that takes the first click, so sliders and buttons work without activating Sidekick.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Where the panel goes: centred under the status item, its top at the bottom of the menu bar,
/// kept inside the visible frame of the item's screen. Pure.
enum MixerPanelLayout {
    static func origin(item: NSRect, size: NSSize, visible: NSRect) -> NSPoint {
        let top = min(item.minY, visible.maxY)
        let x = min(max(item.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        return NSPoint(x: x, y: top - size.height)
    }
}

/// What the panel shows besides the controller and system volume. Owned by `MixerStatusItem`.
@MainActor @Observable
final class MixerPanelModel {
    /// Drives the open/close spring.
    var isShown = false
    /// Displayed (smoothed) levels of tapped apps, sampled at 20 Hz while open. Absent means untapped.
    var levels: [String: Float] = [:]
    var requestingPermission = false
}

// MARK: - Pure helpers

enum MixerFormat {
    /// "70%". Clamped to 0–100%.
    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "0%" }
        return "\(Int((min(1, max(0, value)) * 100).rounded()))%"
    }
}

enum InkSliderMath {
    /// The value under `x` on a track `width` wide whose knob is `knob` wide (the knob stays inside).
    static func value(at x: CGFloat, width: CGFloat, knob: CGFloat) -> Double {
        let usable = width - knob
        guard usable > 0 else { return 0 }
        return Double(min(1, max(0, (x - knob / 2) / usable)))
    }

    static func knobCenter(for value: Double, width: CGFloat, knob: CGFloat) -> CGFloat {
        knob / 2 + CGFloat(min(1, max(0, value))) * max(0, width - knob)
    }
}

enum LevelBarsMath {
    static let bars = 3
    static let floorDB: Float = -50
    /// Per 20 Hz tick, so a peak fades out over about a third of a second.
    static let release: Float = 0.72

    /// How full each bar is (0...1) for a linear peak `level`: −50…0 dBFS spread across the bars in turn.
    static func fills(level: Float) -> [Double] {
        guard level > 0 else { return Array(repeating: 0, count: bars) }
        let db = 20 * log10(min(1, level))
        let span = Double(min(1, max(0, (db - floorDB) / -floorDB))) * Double(bars)
        return (0..<bars).map { min(1, max(0, span - Double($0))) }
    }

    /// Rises at once, falls back gently, like a meter's ballistics.
    static func smoothed(previous: Float, next: Float) -> Float {
        max(next, previous * release)
    }
}

enum SpeakerGlyph {
    static func name(volume: Double?, muted: Bool) -> String {
        if muted { return "speaker.slash.fill" }
        guard let volume else { return "speaker.wave.2.fill" }
        switch volume {
        case ..<0.005: return "speaker.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

enum MixerDisplay {
    /// The controller's rows, plus the row being dragged if it dropped out mid-drag (a silent app
    /// dragged back to 100% stops being listed); it stays put until the finger lifts.
    static func rows(_ rows: [MixerRow], holding held: MixerRow?) -> [MixerRow] {
        guard let held, !rows.contains(where: { $0.id == held.id }) else { return rows }
        return (rows + [held]).sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

// MARK: - Root

/// The card, its shadow and the open spring (scale and opacity from the top edge).
struct MixerRoot: View {
    let controller: TapController
    let systemVolume: SystemVolume
    let model: MixerPanelModel
    let actions: MixerActions
    /// The card's size after layout, so the window can follow it.
    let onSize: (CGSize) -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
        MixerView(controller: controller, systemVolume: systemVolume, model: model, actions: actions)
            .frame(width: MixerPanel.cardWidth)
            .background(shape.fill(Theme.bg()))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.fg(0.1), lineWidth: 1))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
            .shadow(color: .black.opacity(0.16), radius: 14, y: 8)
            .scaleEffect(model.isShown ? 1 : 0.96, anchor: .top)
            .opacity(model.isShown ? 1 : 0)
            .focusEffectDisabled()
            .padding(EdgeInsets(top: MixerPanel.margin.top, leading: MixerPanel.margin.left,
                                bottom: MixerPanel.margin.bottom, trailing: MixerPanel.margin.right))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct MixerActions {
    var openSettings: @MainActor () -> Void
    var grantPermission: @MainActor () -> Void
}

// MARK: - Mixer

struct MixerView: View {
    let controller: TapController
    let systemVolume: SystemVolume
    let model: MixerPanelModel
    let actions: MixerActions

    @State private var held: MixerRow?

    static let maxVisibleRows = 8
    static let rowHeight: CGFloat = 36

    var body: some View {
        VStack(spacing: 0) {
            SystemVolumeRow(volume: systemVolume)
            Hairline()
            appsSection
            Hairline()
            FooterButton(title: "Volume Mixer settings…", action: actions.openSettings)
        }
    }

    @ViewBuilder private var appsSection: some View {
        let rows = MixerDisplay.rows(controller.rows, holding: held)
        VStack(spacing: 0) {
            if controller.needsPermission {
                PermissionBody(requesting: model.requestingPermission, grant: actions.grantPermission)
                    .transition(.opacity)
            } else if rows.isEmpty {
                Text("Nothing's playing right now.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.fg(0.45))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .transition(.opacity)
            } else if rows.count > Self.maxVisibleRows {
                ScrollView(.vertical) { list(rows) }
                    .scrollIndicators(.automatic)
                    .frame(height: CGFloat(Self.maxVisibleRows) * Self.rowHeight + 12)
            } else {
                list(rows)
            }
            if !controller.needsPermission, let notice = controller.notice {
                Text(notice)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.fg(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .animation(Motion.fluid, value: rows.map(\.id))
        .animation(Motion.fluid, value: controller.needsPermission)
        .animation(Motion.fluid, value: controller.notice)
    }

    private func list(_ rows: [MixerRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                AppMixerRow(row: row, controller: controller, model: model) { editing in
                    held = editing ? row : nil
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - System row

private struct SystemVolumeRow: View {
    let volume: SystemVolume
    @State private var live: Double?

    var body: some View {
        let value = live ?? volume.volume ?? 0
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: volume.deviceName.isEmpty ? "Output" : volume.deviceName)
                .lineLimit(1)
            HStack(spacing: 8) {
                Button { volume.toggleMute() } label: {
                    Image(systemName: SpeakerGlyph.name(volume: volume.volume, muted: volume.muted))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.fg(0.85))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!volume.canMute)
                .accessibilityLabel(volume.muted ? "Unmute output" : "Mute output")

                InkSlider(value: value, enabled: volume.volume != nil, label: "Output volume",
                          onChange: { new in
                              live = new
                              if volume.muted { volume.toggleMute() }
                              volume.setVolume(new)
                          },
                          onEditing: { editing in if !editing { live = nil } })
                    .opacity(volume.muted ? 0.45 : 1)

                Text(volume.volume == nil ? "" : MixerFormat.percent(value))
                    .font(Theme.Font.caption.monospacedDigit())
                    .foregroundStyle(Theme.fg(0.55))
                    .frame(width: 34, alignment: .trailing)
            }
            if volume.volume == nil {
                Text("This device controls its own volume")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.fg(0.45))
                    .padding(.leading, 28)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .animation(Motion.snappy, value: volume.muted)
    }
}

// MARK: - App row

private struct AppMixerRow: View {
    let row: MixerRow
    let controller: TapController
    let model: MixerPanelModel
    let onEditing: (Bool) -> Void

    @State private var live: Double?

    private var muted: Bool { row.setting.muted }

    var body: some View {
        let value = live ?? row.setting.volume
        HStack(spacing: 0) {
            AppIconButton(key: row.id, muted: muted) { controller.toggleMute(row.id) }
                // An app on another device is never tapped, so mute would do nothing there either.
                .disabled(row.playsElsewhere)
                .padding(.trailing, 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(Theme.Font.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if row.playsElsewhere {
                    Text("Plays to another device")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.fg(0.45))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(muted ? 0.45 : 1)

            activity
                .frame(width: 14, height: 12)
                .padding(.horizontal, 5)

            InkSlider(value: value, enabled: !row.playsElsewhere, label: "\(row.name) volume",
                      onChange: { new in
                          live = new
                          controller.setVolume(new, for: row.id)
                          // Moving a muted app's slider unmutes it (read live: the row may be stale mid-drag).
                          if controller.rows.first(where: { $0.id == row.id })?.setting.muted == true {
                              controller.toggleMute(row.id)
                          }
                      },
                      onEditing: { editing in
                          if !editing { live = nil }
                          onEditing(editing)
                      })
                .frame(width: 90)
                .opacity(muted ? 0.45 : 1)

            Text(MixerFormat.percent(value))
                .font(Theme.Font.caption.monospacedDigit())
                .foregroundStyle(Theme.fg(muted ? 0.3 : 0.55))
                .frame(width: 34, alignment: .trailing)
                .padding(.leading, 8)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: MixerView.rowHeight)
        .animation(Motion.snappy, value: muted)
    }

    /// Live level for a tapped app, gentle dots for an untapped one that's playing, nothing when silent.
    @ViewBuilder private var activity: some View {
        if row.isPlaying {
            if let level = model.levels[row.id] {
                LevelBars(level: level).transition(.opacity)
            } else {
                PlayingDots().transition(.opacity)
            }
        }
    }
}

/// The app's icon (or a globe for Web content). Clicking it toggles mute; muted shows grey with a badge.
private struct AppIconButton: View {
    let key: String
    let muted: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            icon
                .frame(width: 20, height: 20)
                .grayscale(muted ? 1 : 0)
                .opacity(muted ? 0.4 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if muted {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundStyle(Theme.bg())
                            .frame(width: 11, height: 11)
                            .background(Circle().fill(Theme.fg()))
                            .offset(x: 3, y: 3)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(muted ? "Unmute" : "Mute")
    }

    @ViewBuilder private var icon: some View {
        if key == AppGrouping.webContentKey {
            Image(systemName: "globe")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.fg(0.75))
        } else if let image = AppIcons.icon(for: key) {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            Image(systemName: "app")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.fg(0.6))
        }
    }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

/// Running apps' icons, looked up once per bundle ID.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        guard let icon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
        else { return nil }
        cache[bundleID] = icon
        return icon
    }
}

// MARK: - Permission body

private struct PermissionBody: View {
    let requesting: Bool
    let grant: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Volume Mixer needs System Audio Recording")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.fg(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings", action: grant)
                .buttonStyle(MonoButtonStyle(prominent: true))
                .disabled(requesting)
                .opacity(requesting ? 0.5 : 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }
}

// MARK: - Footer

private struct FooterButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.fg(hovering ? 0.9 : 0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.fg(hovering ? 0.06 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .onHover { hovering = $0 }
        .animation(Motion.snappy, value: hovering)
    }
}

// MARK: - Controls

/// Sidekick's slider: a hairline-thin ink track that fills with ink, and a paper knob.
struct InkSlider: View {
    let value: Double
    var enabled = true
    var label = ""
    let onChange: (Double) -> Void
    var onEditing: (Bool) -> Void = { _ in }

    @State private var dragging = false

    static let knob: CGFloat = 12
    static let track: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let center = InkSliderMath.knobCenter(for: value, width: width, knob: Self.knob)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fg(0.12))
                    .frame(height: Self.track)
                Capsule().fill(Theme.fg(0.88))
                    .frame(width: max(Self.track, center), height: Self.track)
                Circle().fill(Theme.bg())
                    .overlay(Circle().strokeBorder(Theme.fg(0.28), lineWidth: 1))
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                    .frame(width: Self.knob, height: Self.knob)
                    .scaleEffect(dragging ? 1.2 : 1)
                    .offset(x: center - Self.knob / 2)
            }
            .frame(width: width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !dragging {
                            dragging = true
                            onEditing(true)
                        }
                        onChange(InkSliderMath.value(at: drag.location.x, width: width, knob: Self.knob))
                    }
                    .onEnded { _ in
                        dragging = false
                        onEditing(false)
                    })
        }
        .frame(height: 18)
        .animation(Motion.snappy, value: dragging)
        // Outside changes (the volume keys) glide; the knob follows a finger directly.
        .animation(dragging ? nil : Motion.snappy, value: value)
        .opacity(enabled ? 1 : 0.35)
        .allowsHitTesting(enabled)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(MixerFormat.percent(value))
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            switch direction {
            case .increment: onChange(min(1, value + 0.05))
            case .decrement: onChange(max(0, value - 0.05))
            @unknown default: break
            }
        }
    }
}

/// Three bars that light in turn with the app's real level (−50…0 dBFS). Not a decoration.
struct LevelBars: View {
    let level: Float
    private static let heights: [CGFloat] = [5, 8, 11]

    var body: some View {
        let fills = LevelBarsMath.fills(level: level)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<LevelBarsMath.bars, id: \.self) { i in
                let height = Self.heights[i]
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1).fill(Theme.fg(0.14))
                    RoundedRectangle(cornerRadius: 1).fill(Theme.fg(0.85))
                        .frame(height: height * fills[i])
                }
                .frame(width: 2.5, height: height)
            }
        }
        .animation(.linear(duration: 0.05), value: level)
        .accessibilityHidden(true)
    }
}

/// A gentle pulse for an app that's playing but untapped (no audio to measure, so no fake level).
struct PlayingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let wave = 0.5 + 0.5 * sin(t * 2 * .pi / 1.4 - Double(i) * 0.8)
                    Circle().fill(Theme.fg(0.2 + 0.55 * wave))
                        .frame(width: 3, height: 3)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
