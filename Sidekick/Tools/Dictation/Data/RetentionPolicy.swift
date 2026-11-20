import Foundation

enum RetentionPolicy: String, CaseIterable, Identifiable, Sendable {
    case sevenDays, thirtyDays, forever, off

    static let `default` = RetentionPolicy.thirtyDays
    static let storageKey = "retention"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .forever: "Forever"
        case .off: "Don't keep history"
        }
    }

    /// Records older than this are deleted; nil keeps everything.
    func cutoff(now: Date) -> Date? {
        switch self {
        case .sevenDays: now.addingTimeInterval(-7 * 86_400)
        case .thirtyDays: now.addingTimeInterval(-30 * 86_400)
        case .forever: nil
        case .off: .distantFuture
        }
    }

    var keepsNew: Bool { self != .off }

    static func current(_ defaults: UserDefaults = .standard) -> RetentionPolicy {
        RetentionPolicy(rawValue: defaults.string(forKey: storageKey) ?? "") ?? .default
    }
}
