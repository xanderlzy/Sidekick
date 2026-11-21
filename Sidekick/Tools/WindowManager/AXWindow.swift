import AppKit
import ApplicationServices

/// Abstraction over a manipulable window. Frames are in AX coordinates
/// (global, origin top-left of the primary screen, y down).
@MainActor protocol WindowHandle: AnyObject {
    var id: AnyHashable { get }
    var frame: CGRect? { get }
    var isFullScreen: Bool { get }
    var isMinimized: Bool { get }
    @discardableResult func setFrame(_ frame: CGRect) -> Bool
}

/// Hashable wrapper around an AXUIElement using CFHash/CFEqual.
struct AXElementKey: Hashable {
    let element: AXUIElement

    init(_ element: AXUIElement) { self.element = element }

    static func == (lhs: AXElementKey, rhs: AXElementKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

@MainActor
final class AXWindow: WindowHandle {
    private let element: AXUIElement

    /// Caps how long one AX call may wait on a busy app, so it can't stall the main thread.
    static let messagingTimeout: Float = 0.25

    init(element: AXUIElement) {
        self.element = element
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
    }

    var id: AnyHashable { AnyHashable(AXElementKey(element)) }

    var frame: CGRect? {
        guard let origin = point(kAXPositionAttribute), let size = size(kAXSizeAttribute) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    var isFullScreen: Bool { bool("AXFullScreen") }
    var isMinimized: Bool { bool(kAXMinimizedAttribute) }

    @discardableResult
    func setFrame(_ frame: CGRect) -> Bool {
        // Size, position, size: some apps clamp size to the current screen.
        let first = set(size: frame.size)
        let moved = set(position: frame.origin)
        let second = set(size: frame.size)
        return first && moved && second
    }

    static func focused() -> AXWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXWindow(element: value as! AXUIElement)
    }

    static func at(_ axPoint: CGPoint) -> AXWindow? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(axPoint.x), Float(axPoint.y), &hit) == .success,
              let hit else { return nil }
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(hit, kAXRoleAttribute as CFString, &role) == .success,
           (role as? String) == kAXWindowRole {
            return AXWindow(element: hit)
        }
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(hit, kAXWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return AXWindow(element: window as! AXUIElement)
    }

    // MARK: - Attribute helpers

    private func value(_ attribute: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &v) == .success else { return nil }
        return v
    }

    private func point(_ attribute: String) -> CGPoint? {
        guard let v = value(attribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    private func size(_ attribute: String) -> CGSize? {
        guard let v = value(attribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    private func bool(_ attribute: String) -> Bool {
        (value(attribute) as? Bool) ?? false
    }

    private func set(size: CGSize) -> Bool {
        var s = size
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, v) == .success
    }

    private func set(position: CGPoint) -> Bool {
        var p = position
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, v) == .success
    }
}
