import AppKit

/// Metrics shared by the mixer menu's custom rows, so they line up with each other and with the
/// menu's own text items. System fonts and colours only; the menu draws its own background.
enum MixerMenuMetrics {
    /// The menu's fixed width. Every custom row is this wide, so the menu never changes width as rows come and go.
    static let width: CGFloat = 300
    /// Leading and trailing inset of a row's content (lines up with standard item titles).
    static let inset: CGFloat = 14
    /// The icon column (app icon, speaker glyph).
    static let icon: CGFloat = 16
    static let iconGap: CGFloat = 6
    /// Where names and sliders start: past the icon column.
    static var textX: CGFloat { inset + icon + iconGap }
    static let percentWidth: CGFloat = 40
    static let percentGap: CGFloat = 6

    static var menuFont: NSFont { NSFont.menuFont(ofSize: 0) }
    static var captionFont: NSFont { NSFont.systemFont(ofSize: 11) }
    static var percentFont: NSFont { NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular) }
}

/// A slider that reports when the user lets go, so a row can hold still (and ignore outside updates) mid-drag.
final class MixerSlider: NSSlider {
    private(set) var isTracking = false
    var onEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        isTracking = true
        super.mouseDown(with: event) // runs the tracking loop until mouse up
        isTracking = false
        onEnded?()
    }

    static func make() -> MixerSlider {
        let slider = MixerSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
        slider.controlSize = .small
        slider.isContinuous = true
        return slider
    }
}

@MainActor private func makeLabel(_ font: NSFont, _ color: NSColor) -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.font = font
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    return label
}

@MainActor private func makeIconButton() -> NSButton {
    let button = NSButton(frame: .zero)
    button.isBordered = false
    button.bezelStyle = .shadowlessSquare
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyUpOrDown
    button.setButtonType(.momentaryPushIn)
    button.title = ""
    return button
}

// MARK: - Text rows

/// The bold "Sound" title at the top, like the title of Apple's Sound menu.
final class MixerHeaderView: NSView {
    private let label = makeLabel(NSFont.boldSystemFont(ofSize: MixerMenuMetrics.menuFont.pointSize), .labelColor)

    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: MixerMenuMetrics.width, height: 24))
        label.stringValue = title
        label.setAccessibilityRole(.staticText)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: MixerMenuMetrics.inset, y: bounds.height - height - 3,
                             width: bounds.width - 2 * MixerMenuMetrics.inset, height: height)
    }
}

/// Grey text that wraps inside the menu's width: the device name, empty and permission states and notices.
final class MixerCaptionView: NSView {
    private let label: NSTextField
    private let leading: CGFloat

    /// `leading` is where the text starts; `font` is the caption or the menu font.
    init(text: String, font: NSFont, leading: CGFloat, top: CGFloat = 2, bottom: CGFloat = 4) {
        label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        self.leading = leading
        let width = MixerMenuMetrics.width - leading - MixerMenuMetrics.inset
        let height = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1000)).height
            ?? font.pointSize + 4
        super.init(frame: NSRect(x: 0, y: 0, width: MixerMenuMetrics.width, height: ceil(height) + top + bottom))
        label.frame = NSRect(x: leading, y: top, width: width, height: ceil(height))
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
}

// MARK: - System row

/// The output device: speaker glyph (click to mute), slider and percentage, like Apple's Sound menu.
final class MixerSystemRowView: NSView {
    var onToggleMute: (() -> Void)?
    var onChange: ((Double) -> Void)?

    private let glyph = makeIconButton()
    private let slider = MixerSlider.make()
    private let percent = makeLabel(MixerMenuMetrics.percentFont, .secondaryLabelColor)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: MixerMenuMetrics.width, height: 26))
        glyph.target = self
        glyph.action = #selector(toggleMute)
        glyph.contentTintColor = .labelColor
        slider.target = self
        slider.action = #selector(slide)
        slider.setAccessibilityLabel("Output volume")
        percent.alignment = .right
        for view in [glyph, slider, percent] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func configure(volume: Double?, muted: Bool, canMute: Bool) {
        let image = NSImage(systemSymbolName: SpeakerGlyph.name(volume: volume, muted: muted),
                            accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        image?.isTemplate = true
        glyph.image = image
        glyph.isEnabled = canMute
        glyph.setAccessibilityLabel(muted ? "Unmute output" : "Mute output")
        slider.isEnabled = volume != nil
        if !slider.isTracking { slider.doubleValue = volume ?? 0 }
        slider.alphaValue = muted ? 0.45 : 1
        percent.stringValue = volume == nil ? "" : MixerFormat.percent(slider.doubleValue)
        percent.textColor = muted ? .tertiaryLabelColor : .secondaryLabelColor
        layoutContent()
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    private func layoutContent() {
        let m = MixerMenuMetrics.self
        let mid = bounds.midY
        glyph.frame = NSRect(x: m.inset - 1, y: mid - 10, width: m.icon + 4, height: 20)
        let percentX = bounds.width - m.inset - m.percentWidth
        slider.frame = NSRect(x: m.textX, y: mid - 10, width: percentX - m.percentGap - m.textX, height: 20)
        let height = percent.intrinsicContentSize.height
        percent.frame = NSRect(x: percentX, y: mid - height / 2, width: m.percentWidth, height: height)
    }

    @objc private func toggleMute() { onToggleMute?() }

    @objc private func slide() {
        percent.stringValue = MixerFormat.percent(slider.doubleValue)
        onChange?(slider.doubleValue)
    }
}

// MARK: - App row

/// One app: its icon (click to mute), name and a playing mark on the first line; a slider and percentage
/// beneath. A muted app dims its icon and slider; the slider stays draggable, and dragging unmutes.
final class MixerAppRowView: NSView {
    var onToggleMute: (() -> Void)?
    var onChange: ((Double) -> Void)?
    var onEnded: (() -> Void)?

    private let icon = makeIconButton()
    private let name = makeLabel(MixerMenuMetrics.menuFont, .labelColor)
    private let playing = NSImageView()
    private let slider = MixerSlider.make()
    private let percent = makeLabel(MixerMenuMetrics.percentFont, .secondaryLabelColor)
    private let elsewhere: NSTextField?

    static func height(playsElsewhere: Bool) -> CGFloat { playsElsewhere ? 60 : 46 }

    init(playsElsewhere: Bool) {
        elsewhere = playsElsewhere ? makeLabel(MixerMenuMetrics.captionFont, .secondaryLabelColor) : nil
        super.init(frame: NSRect(x: 0, y: 0, width: MixerMenuMetrics.width,
                                 height: Self.height(playsElsewhere: playsElsewhere)))
        icon.target = self
        icon.action = #selector(toggleMute)
        icon.contentTintColor = .secondaryLabelColor // only the template globe uses it
        let mark = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Playing")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        playing.image = mark
        playing.contentTintColor = .tertiaryLabelColor
        playing.imageScaling = .scaleNone
        slider.target = self
        slider.action = #selector(slide)
        slider.onEnded = { [weak self] in self?.onEnded?() }
        percent.alignment = .right
        elsewhere?.stringValue = MixerMenuModel.playsElsewhere
        for view in [icon, name, playing, slider, percent] { addSubview(view) }
        if let elsewhere { addSubview(elsewhere) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func configure(row: MixerRow, image: NSImage?) {
        let muted = row.setting.muted
        if icon.image !== image { icon.image = image }
        icon.alphaValue = muted ? 0.4 : 1
        // An app on another device is never tapped, so mute would do nothing there either.
        icon.isEnabled = !row.playsElsewhere
        icon.setAccessibilityLabel(muted ? "Unmute \(row.name)" : "Mute \(row.name)")
        name.stringValue = row.name
        name.textColor = muted ? .secondaryLabelColor : .labelColor
        playing.isHidden = !row.isPlaying
        slider.isEnabled = !row.playsElsewhere
        slider.setAccessibilityLabel("\(row.name) volume")
        if !slider.isTracking { slider.doubleValue = row.setting.volume }
        slider.alphaValue = muted ? 0.45 : 1
        percent.stringValue = MixerFormat.percent(slider.doubleValue)
        percent.textColor = muted || row.playsElsewhere ? .tertiaryLabelColor : .secondaryLabelColor
        // Laid out here too: the name's width decides where the playing mark goes, and a view in an open
        // menu isn't guaranteed a layout pass before it draws.
        layoutContent()
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    private func layoutContent() {
        let m = MixerMenuMetrics.self
        // Line 1: icon, name, playing mark.
        let line1: CGFloat = 5
        icon.frame = NSRect(x: m.inset, y: line1 + 1, width: m.icon, height: m.icon)
        let nameHeight = name.intrinsicContentSize.height
        let markWidth: CGFloat = 14
        let maxName = bounds.width - m.textX - m.inset - markWidth - 4
        // The label gets all the room there is (so it only truncates when it must); the mark follows the text.
        name.frame = NSRect(x: m.textX, y: line1 + (18 - nameHeight) / 2, width: maxName, height: nameHeight)
        let textWidth = min(ceil(name.attributedStringValue.size().width) + 4, maxName)
        playing.frame = NSRect(x: m.textX + textWidth + 2, y: line1 + 2, width: markWidth, height: 14)
        // Line 2: slider and percentage.
        let line2 = line1 + 20
        let percentX = bounds.width - m.inset - m.percentWidth
        slider.frame = NSRect(x: m.textX, y: line2, width: percentX - m.percentGap - m.textX, height: 18)
        let height = percent.intrinsicContentSize.height
        percent.frame = NSRect(x: percentX, y: line2 + (18 - height) / 2, width: m.percentWidth, height: height)
        if let elsewhere {
            let h = elsewhere.intrinsicContentSize.height
            elsewhere.frame = NSRect(x: m.textX, y: line2 + 19, width: bounds.width - m.textX - m.inset, height: h)
        }
    }

    @objc private func toggleMute() { onToggleMute?() }

    @objc private func slide() {
        percent.stringValue = MixerFormat.percent(slider.doubleValue)
        onChange?(slider.doubleValue)
    }
}
