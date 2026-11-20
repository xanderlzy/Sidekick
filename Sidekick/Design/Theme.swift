import SwiftUI
import AppKit

/// Sidekick's visual language: pure black and white, opacity steps only.
/// `fg` is ink (black in light mode, white in dark mode); `bg` is paper (the inverse).
enum Theme {
    static func clamp(_ opacity: Double) -> Double { min(1, max(0, opacity)) }

    static func fg(_ opacity: Double = 1) -> Color { ink.opacity(clamp(opacity)) }
    static func bg(_ opacity: Double = 1) -> Color { paper.opacity(clamp(opacity)) }

    static let ink = Color(nsColor: NSColor(name: "SidekickInk") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black
    })
    static let paper = Color(nsColor: NSColor(name: "SidekickPaper") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white
    })

    enum Font {
        static let display = SwiftUI.Font.system(size: 56, weight: .light)
        static let title = SwiftUI.Font.system(size: 22, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13, weight: .regular)
        static let caption = SwiftUI.Font.system(size: 11, weight: .medium)
    }

    static let displayTracking: CGFloat = -1.5
    static let corner: CGFloat = 14
    /// Pop-up pickers in settings rows share one width so their edges line up down the page.
    static let pickerWidth: CGFloat = 168

    /// The spacing scale every page uses.
    enum Space {
        /// Title to subtitle, chip to chip.
        static let tight: CGFloat = 6
        /// Between cards in a list.
        static let item: CGFloat = 10
        /// Page header to content, and between sections.
        static let section: CGFloat = 28
    }
}

/// Shared spring presets so every motion in the app feels like the same material.
enum Motion {
    static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.78)
    static let fluid = Animation.spring(response: 0.5, dampingFraction: 0.82)
    static let gentle = Animation.spring(response: 0.7, dampingFraction: 0.9)
}
