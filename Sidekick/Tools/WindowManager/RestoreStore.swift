import CoreGraphics

/// Remembers each window's frame before its first managed move, for Restore.
struct RestoreStore {
    static let capacity = 100

    private var frames: [AnyHashable: CGRect] = [:]
    private var order: [AnyHashable] = []

    mutating func rememberIfNeeded(_ frame: CGRect, for window: AnyHashable) {
        guard frames[window] == nil else { return }
        frames[window] = frame
        order.append(window)
        while order.count > Self.capacity {
            frames[order.removeFirst()] = nil
        }
    }

    func original(for window: AnyHashable) -> CGRect? { frames[window] }

    mutating func take(for window: AnyHashable) -> CGRect? {
        guard let f = frames.removeValue(forKey: window) else { return nil }
        order.removeAll { $0 == window }
        return f
    }
}
