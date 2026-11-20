import AppKit
import CoreGraphics

struct WindowInfo: Equatable, Sendable {
    let id: CGWindowID
    let pid: pid_t
    /// AppKit coordinates (bottom-left origin).
    let frame: CGRect
    let title: String
    let appName: String
}

enum WindowFinder {
    private static let minSide: CGFloat = 100

    static func pick(from list: [[String: Any]], frontmostPID: pid_t, ownPID: pid_t,
                     primaryScreenHeight: CGFloat) -> WindowInfo? {
        guard frontmostPID != ownPID else { return nil }
        for entry in list {
            guard let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid == frontmostPID,
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let cg = bounds(entry[kCGWindowBounds as String]),
                  cg.width >= minSide, cg.height >= minSide
            else { continue }
            let frame = CGRect(x: cg.minX, y: primaryScreenHeight - cg.minY - cg.height,
                               width: cg.width, height: cg.height)
            return WindowInfo(id: number, pid: pid, frame: frame,
                              title: entry[kCGWindowName as String] as? String ?? "",
                              appName: entry[kCGWindowOwnerName as String] as? String ?? "")
        }
        return nil
    }

    private static func bounds(_ raw: Any?) -> CGRect? {
        if let cf = raw as? NSDictionary, let rect = CGRect(dictionaryRepresentation: cf as CFDictionary) {
            return rect
        }
        if let d = raw as? [String: CGFloat], let x = d["X"], let y = d["Y"],
           let w = d["Width"], let h = d["Height"] {
            return CGRect(x: x, y: y, width: w, height: h)
        }
        return nil
    }

    static func frontmost() -> WindowInfo? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let height = NSScreen.screens.first?.frame.height,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return pick(from: list, frontmostPID: pid, ownPID: ProcessInfo.processInfo.processIdentifier,
                    primaryScreenHeight: height)
    }

    static func exists(_ id: CGWindowID) -> Bool {
        contains(id, options: .optionAll)
    }

    static func isOnScreen(_ id: CGWindowID) -> Bool {
        contains(id, options: .optionOnScreenOnly)
    }

    private static func contains(_ id: CGWindowID, options: CGWindowListOption) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }
    }
}
