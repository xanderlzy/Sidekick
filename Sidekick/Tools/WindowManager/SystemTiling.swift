import Foundation

/// Reads macOS's own "Drag windows to screen edges to tile" settings (macOS 15+).
enum SystemTiling {
    static let suiteName = "com.apple.WindowManager"
    static let edgeKey = "EnableTilingByEdgeDrag"
    static let topEdgeKey = "EnableTopTilingByEdgeDrag"

    /// True when either edge-tiling setting is on. A missing key is on, the macOS default.
    static func edgeTilingEnabled(_ defaults: UserDefaults? = UserDefaults(suiteName: suiteName)) -> Bool {
        guard let defaults else { return true }
        return [edgeKey, topEdgeKey].contains { defaults.object(forKey: $0) as? Bool ?? true }
    }
}
