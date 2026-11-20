import Foundation
import Observation

@MainActor @Observable
final class ToolRegistry {
    static let defaultsKey = "enabledTools"

    let tools: [any Tool]
    @ObservationIgnored private let defaults: UserDefaults
    private var enabledIDs: Set<String>
    @ObservationIgnored private var running = false

    init(tools: [any Tool], defaults: UserDefaults = .standard, defaultEnabled: Set<String> = ["keepOnTop"]) {
        self.tools = tools
        self.defaults = defaults
        if let stored = defaults.array(forKey: Self.defaultsKey) as? [String] {
            enabledIDs = Set(stored)
        } else {
            enabledIDs = defaultEnabled
        }
    }

    var enabled: [any Tool] { tools.filter { enabledIDs.contains($0.id) } }

    func isEnabled(_ id: String) -> Bool { enabledIDs.contains(id) }

    func setEnabled(_ id: String, _ on: Bool) {
        guard let tool = tools.first(where: { $0.id == id }), on != enabledIDs.contains(id) else { return }
        if on { enabledIDs.insert(id) } else { enabledIDs.remove(id) }
        defaults.set(tools.map(\.id).filter { enabledIDs.contains($0) }, forKey: Self.defaultsKey)
        guard running else { return }
        if on { tool.start() } else { tool.stop() }
    }

    func startEnabled() {
        guard !running else { return }
        running = true
        enabled.forEach { $0.start() }
    }
}
