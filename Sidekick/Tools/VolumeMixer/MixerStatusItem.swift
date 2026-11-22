import AppKit
import Observation

/// The mixer's own menu bar presence. Installed only while the tool is on.
@MainActor
protocol MixerMenuBar: AnyObject {
    func install()
    func remove()
    var isInstalled: Bool { get }
}

/// A `speaker.wave.2` status item with a native `NSMenu`: the same material, font, highlight, Esc and
/// click-outside behaviour as Sidekick's own menu and Apple's Sound menu.
///
/// While the menu is open (and only then) it observes the controller and the system volume and updates
/// the open menu's items in place. Menus track in `.eventTracking` run loop mode, so each observation hop
/// runs in `.common` modes. Closing stops the observation; `remove()` closes the menu and drops the item.
@MainActor
final class MixerStatusItem: NSObject, MixerMenuBar, NSMenuDelegate {
    private let controller: TapController
    private let systemVolume: SystemVolume
    private let openSettings: @MainActor () -> Void

    private var item: NSStatusItem?
    private var menu: NSMenu?
    private(set) var isOpen = false
    /// Bumped on close and remove, so a queued observation hop from an earlier opening does nothing.
    private var generation = 0
    /// The menu's items by key, reused across updates so a slider under the pointer is never replaced.
    private var items: [String: NSMenuItem] = [:]
    private var icons: [String: NSImage] = [:]
    /// The row being dragged, kept listed until the pointer lifts (see `MixerDisplay.rows(_:holding:)`).
    private var held: MixerRow?
    private var requestingPermission = false

    var isInstalled: Bool { item != nil }

    init(controller: TapController, systemVolume: SystemVolume, openSettings: @escaping @MainActor () -> Void) {
        self.controller = controller
        self.systemVolume = systemVolume
        self.openSettings = openSettings
    }

    // MARK: MixerMenuBar

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "Volume Mixer")
            image?.isTemplate = true
            button.image = image
            button.setAccessibilityLabel("Volume Mixer")
        }
        let menu = NSMenu(title: "Volume Mixer")
        menu.autoenablesItems = false
        menu.minimumWidth = MixerMenuMetrics.width
        menu.delegate = self
        item.menu = menu
        self.item = item
        self.menu = menu
    }

    /// Closes the menu at once, stops every update and drops the item. Idempotent.
    func remove() {
        generation += 1
        if isOpen { menu?.cancelTrackingWithoutAnimation() }
        isOpen = false
        held = nil
        menu?.delegate = nil
        menu?.removeAllItems()
        items.removeAll()
        icons.removeAll()
        if let item {
            item.menu = nil
            NSStatusBar.system.removeStatusItem(item)
        }
        item = nil
        menu = nil
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu, isInstalled else { return }
        isOpen = true
        generation += 1
        controller.refresh()
        update()
        observe(generation)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu, isOpen else { return }
        isOpen = false
        generation += 1
        held = nil
    }

    // MARK: Live updates

    /// Re-arms on every change; the hop runs in `.common` modes so it fires while the menu tracks.
    private func observe(_ generation: Int) {
        withObservationTracking {
            _ = controller.rows
            _ = controller.needsPermission
            _ = controller.notice
            _ = systemVolume.deviceName
            _ = systemVolume.volume
            _ = systemVolume.muted
            _ = systemVolume.canMute
        } onChange: { [weak self] in
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated { self?.changed(generation) }
            }
        }
    }

    private func changed(_ generation: Int) {
        guard isOpen, generation == self.generation else { return }
        update()
        observe(generation)
    }

    /// Brings the menu's items in line with the current state, reusing items (and their views) by key.
    private func update() {
        guard let menu else { return }
        let rows = MixerDisplay.rows(controller.rows, holding: held)
        let entries = MixerMenuModel.entries(rows: rows, needsPermission: controller.needsPermission,
                                             notice: controller.notice, deviceName: systemVolume.deviceName)
        var next: [String: NSMenuItem] = [:]
        var ordered: [NSMenuItem] = []
        var separators = 0
        for entry in entries {
            let key: String
            switch entry {
            case .header(let title): key = "header:\(title)"
            case .system: key = "system"
            case .deviceCaption(let name): key = "device:\(name):\(systemVolume.volume == nil)"
            case .separator:
                key = "separator:\(separators)"
                separators += 1
            case .sectionHeader(let title): key = "section:\(title)"
            case .app(let row): key = "app:\(row.id):\(row.playsElsewhere)"
            case .caption(let text): key = "caption:\(text)"
            case .action(let title): key = "action:\(title)"
            }
            let item = items[key] ?? makeItem(entry)
            configure(item, entry)
            next[key] = item
            ordered.append(item)
        }
        items = next
        apply(ordered, to: menu)
    }

    /// Removes, inserts and moves only what changed, so the open menu keeps its other items (and any drag).
    private func apply(_ ordered: [NSMenuItem], to menu: NSMenu) {
        let wanted = Set(ordered.map(ObjectIdentifier.init))
        for item in menu.items where !wanted.contains(ObjectIdentifier(item)) { menu.removeItem(item) }
        for (index, item) in ordered.enumerated() {
            if index < menu.numberOfItems, menu.item(at: index) === item { continue }
            if item.menu === menu { menu.removeItem(item) }
            menu.insertItem(item, at: index)
        }
    }

    // MARK: Items

    private func makeItem(_ entry: MixerMenuEntry) -> NSMenuItem {
        let m = MixerMenuMetrics.self
        switch entry {
        case .header(let title):
            return viewItem(MixerHeaderView(title: title))
        case .system:
            let view = MixerSystemRowView()
            view.onToggleMute = { [weak self] in self?.systemVolume.toggleMute() }
            view.onChange = { [weak self] value in
                guard let self else { return }
                if self.systemVolume.muted { self.systemVolume.toggleMute() }
                self.systemVolume.setVolume(value)
            }
            return viewItem(view)
        case .deviceCaption(let name):
            let text = systemVolume.volume == nil ? "\(name)\n\(MixerMenuModel.ownVolume)" : name
            return viewItem(MixerCaptionView(text: text, font: m.captionFont, leading: m.textX, top: 0, bottom: 4))
        case .separator:
            return .separator()
        case .sectionHeader(let title):
            return .sectionHeader(title: title)
        case .app(let row):
            let view = MixerAppRowView(playsElsewhere: row.playsElsewhere)
            let id = row.id
            view.onToggleMute = { [weak self] in self?.controller.toggleMute(id) }
            view.onChange = { [weak self] value in self?.slide(id, to: value) }
            view.onEnded = { [weak self] in self?.endSlide(id) }
            return viewItem(view)
        case .caption(let text):
            return viewItem(MixerCaptionView(text: text, font: m.menuFont, leading: m.inset, top: 3, bottom: 3))
        case .action(let title):
            let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = title
            return item
        }
    }

    private func viewItem(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func configure(_ item: NSMenuItem, _ entry: MixerMenuEntry) {
        switch entry {
        case .system:
            (item.view as? MixerSystemRowView)?.configure(volume: systemVolume.volume, muted: systemVolume.muted,
                                                          canMute: systemVolume.canMute)
        case .app(let row):
            (item.view as? MixerAppRowView)?.configure(row: row, image: icon(for: row.id))
        case .action(let title) where title == MixerMenuModel.openSettingsTitle:
            item.isEnabled = !requestingPermission
        default:
            break
        }
    }

    private func icon(for key: String) -> NSImage? {
        if let cached = icons[key] { return cached }
        guard let image = MixerAppIcon.image(for: key, size: MixerMenuMetrics.icon) else { return nil }
        icons[key] = image
        return image
    }

    // MARK: Actions

    private func slide(_ key: String, to value: Double) {
        let row = controller.rows.first { $0.id == key } ?? (held?.id == key ? held : nil)
        controller.setVolume(value, for: key)
        // Moving a muted app's slider unmutes it.
        if controller.rows.first(where: { $0.id == key })?.setting.muted == true { controller.toggleMute(key) }
        // Taken after the change, so a row that drops out mid-drag shows the new value, unmuted.
        if let row { held = MixerDisplay.dragged(row, to: value) }
    }

    private func endSlide(_ key: String) {
        guard held?.id == key else { return }
        held = nil
        if isOpen { update() }
    }

    @objc private func choose(_ sender: NSMenuItem) {
        switch sender.representedObject as? String {
        case MixerMenuModel.settingsTitle: openSettings()
        case MixerMenuModel.openSettingsTitle: grantPermission()
        default: break
        }
    }

    /// Grant: ask (may show the system prompt); if that didn't grant, open the Privacy pane. Then refresh.
    private func grantPermission() {
        guard isInstalled, !requestingPermission else { return }
        requestingPermission = true
        Task { @MainActor [weak self] in
            let state = await SystemAudioPermission.request()
            guard let self else { return }
            self.requestingPermission = false
            // Nothing to do if the tool was turned off while the request ran.
            guard self.isInstalled else { return }
            if !state.isGranted { Permissions.openSettings(.systemAudio) }
            self.controller.refresh()
        }
    }
}
