import AppKit
import SwiftUI

/// The mixer's own menu bar presence. Installed only while the tool is on.
@MainActor
protocol MixerMenuBar: AnyObject {
    func install()
    func remove()
    var isInstalled: Bool { get }
}

/// A `speaker.wave.2` status item that toggles the mixer panel underneath it.
///
/// While the panel is open (and only then) it holds: a global mouse monitor (click in another app
/// closes), a local mouse monitor (click in another Sidekick window closes), local and global key
/// monitors for Esc (the panel never becomes key, so Esc reaches it only this way; the global one
/// needs Accessibility and otherwise stays quiet), Space and screen observers, and the 20 Hz level
/// sampler. Closing removes all of them; `remove()` closes and drops the item.
@MainActor
final class MixerStatusItem: NSObject, MixerMenuBar {
    private let controller: TapController
    private let systemVolume: SystemVolume
    private let openSettings: @MainActor () -> Void
    private let model = MixerPanelModel()

    private var item: NSStatusItem?
    private var panel: MixerPanel?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var sampler: Task<Void, Never>?
    private var hideWork: DispatchWorkItem?
    private var shrinkWork: DispatchWorkItem?
    private var cardSize = CGSize(width: MixerPanel.cardWidth, height: 200)
    private(set) var isOpen = false

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
            button.target = self
            button.action = #selector(toggle(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.setAccessibilityLabel("Volume Mixer")
        }
        self.item = item
    }

    /// Closes the panel at once, removes every monitor, stops the sampler and drops the item. Idempotent.
    func remove() {
        close(animated: false)
        hideWork?.cancel()
        hideWork = nil
        shrinkWork?.cancel()
        shrinkWork = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    // MARK: Open / close

    @objc private func toggle(_ sender: Any?) {
        isOpen ? close() : open()
    }

    private func open() {
        guard let button = item?.button, let itemWindow = button.window, !isOpen else { return }
        isOpen = true
        hideWork?.cancel()
        hideWork = nil
        controller.refresh()
        sampleLevels()

        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.isShown = false
        place(panel, itemFrame: itemWindow.frame, screen: itemWindow.screen)
        // Lay out now so the window takes the card's real height before it shows.
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        installMonitors()
        startSampling()
        // Pressed look while open (after the click is handled, or the press clears it). macOS 27.2 draws
        // no highlight for it; kept because it is the documented call and costs nothing.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isOpen else { return }
            self.item?.button?.highlight(true)
        }
        // One turn later, so the panel lays out at rest before it springs open.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isOpen else { return }
            withAnimation(Motion.snappy) { self.model.isShown = true }
        }
    }

    private func close(animated: Bool = true) {
        guard isOpen else { return }
        isOpen = false
        removeMonitors()
        stopSampling()
        item?.button?.highlight(false)
        guard let panel else { return }
        panel.ignoresMouseEvents = true
        guard animated else {
            model.isShown = false
            panel.orderOut(nil)
            return
        }
        withAnimation(Motion.snappy) { model.isShown = false }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isOpen else { return }
            self.panel?.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func makePanel() -> MixerPanel {
        let panel = MixerPanel()
        let actions = MixerActions(
            openSettings: { [weak self] in
                self?.close()
                self?.openSettings()
            },
            grantPermission: { [weak self] in self?.grantPermission() })
        let root = MixerRoot(controller: controller, systemVolume: systemVolume, model: model, actions: actions,
                             onSize: { [weak self] size in self?.cardResized(size) })
        let host = FirstMouseHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    /// Positions the panel under the item, on the item's screen.
    private func place(_ panel: MixerPanel, itemFrame: NSRect, screen: NSScreen?) {
        let size = MixerPanel.windowSize(for: cardSize)
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? itemFrame
        // The margins are transparent; line the card (not the window) up under the menu bar.
        let origin = MixerPanelLayout.origin(item: itemFrame, size: size, visible: visible)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    /// The window follows the card, top edge fixed. It grows at once (the card animates inside it) and
    /// shrinks once the card's own animation has settled, so nothing is clipped mid-spring.
    private func cardResized(_ size: CGSize) {
        guard size.height > 0, size != cardSize else { return }
        cardSize = size
        shrinkWork?.cancel()
        shrinkWork = nil
        guard let panel else { return }
        let target = MixerPanel.windowSize(for: size)
        // Grow at once; shrink at once too while the card isn't on screen yet (no spring to wait for).
        if target.height >= panel.frame.height || !model.isShown {
            resize(panel, to: target)
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, let panel = self.panel else { return }
                self.resize(panel, to: MixerPanel.windowSize(for: self.cardSize))
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }

    private func resize(_ panel: MixerPanel, to size: NSSize) {
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height),
                       display: true)
    }

    // MARK: Permission

    /// Grant: ask (may show the system prompt); if that didn't grant, open the Privacy pane. Then refresh.
    private func grantPermission() {
        guard !model.requestingPermission else { return }
        model.requestingPermission = true
        Task { @MainActor [weak self] in
            let state = await SystemAudioPermission.request()
            guard let self else { return }
            if !state.isGranted {
                self.close()
                Permissions.openSettings(.systemAudio)
            }
            self.controller.refresh()
            self.model.requestingPermission = false
        }
    }

    // MARK: Monitors

    private func installMonitors() {
        removeMonitors()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                // The menu bar delivers a click on our own item here too; its action toggles instead.
                guard let self, !self.isOverItem(NSEvent.mouseLocation) else { return }
                self.close()
            }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            let window = event.window
            MainActor.assumeIsolated {
                // The panel handles its own clicks; the item's own click toggles.
                guard let self, window !== self.panel, window !== self.item?.button?.window,
                      !self.isOverItem(NSEvent.mouseLocation) else { return }
                self.close()
            }
            return event
        }) {
            monitors.append(local)
        }
        if let localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == Self.escape else { return event }
            MainActor.assumeIsolated { self?.close() }
            return nil
        }) {
            monitors.append(localKeys)
        }
        if let globalKeys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let isEscape = event.keyCode == Self.escape
            MainActor.assumeIsolated { if isEscape { self?.close() } }
        }) {
            monitors.append(globalKeys)
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(animated: false) }
        })
    }

    private func isOverItem(_ point: NSPoint) -> Bool {
        guard let frame = item?.button?.window?.frame else { return false }
        return frame.contains(point)
    }

    private func removeMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    private static let escape: UInt16 = 53

    // MARK: Levels

    private func startSampling() {
        sampler?.cancel()
        sampler = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled else { return }
                self.sampleLevels()
            }
        }
    }

    private func stopSampling() {
        sampler?.cancel()
        sampler = nil
    }

    /// Tapped rows only: `level(for:)` is nil for untapped apps, which show the playing dots instead.
    private func sampleLevels() {
        var next: [String: Float] = [:]
        for row in controller.rows {
            guard let level = controller.level(for: row.id) else { continue }
            next[row.id] = LevelBarsMath.smoothed(previous: model.levels[row.id] ?? 0, next: level)
        }
        if next != model.levels { model.levels = next }
    }
}
