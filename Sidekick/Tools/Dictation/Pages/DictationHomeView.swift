import SwiftUI

struct DictationHomeView: View {
    let env: DictationEnvironment
    @State private var shown = false
    @State private var nudgeDismissed = false
    @AppStorage("hotkey") private var hotkey = HotkeyKey.fn.rawValue
    @AppStorage(ParrotImporter.countKey) private var parrotImportCount = 0

    private var stats: Stats { env.stats.stats }
    private var key: HotkeyKey { HotkeyKey(rawValue: hotkey) ?? .fn }
    private var showNudge: Bool {
        !nudgeDismissed && (env.controller.aiUnavailableNudge || !env.polishAvailable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            VStack(alignment: .leading, spacing: 6) {
                Text(greeting).font(Theme.Font.title)
                Text("Hold \(key.shortName) to dictate anywhere. Double-tap to go hands-free.")
                    .font(Theme.Font.body).foregroundStyle(Theme.fg(0.5))
            }
            HStack(alignment: .top, spacing: 48) {
                StatBlock(value: Formatting.count(shown ? stats.totalWords : 0), label: "words dictated")
                StatBlock(value: Formatting.duration(shown ? stats.timeSavedSeconds : 0), label: "time saved")
                StatBlock(value: "\(shown ? stats.streak() : 0)", label: stats.streak() == 1 ? "day streak" : "days streak")
            }
            if parrotImportCount > 0 {
                Nudge(title: "Imported \(parrotImportCount) \(parrotImportCount == 1 ? "dictation" : "dictations") from Parrot",
                      detail: "Your history and settings came along. Find them under History.",
                      dismiss: { withAnimation(Motion.fluid) { UserDefaults.standard.removeObject(forKey: ParrotImporter.countKey) } })
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if showNudge {
                Nudge(title: "Turn on Apple Intelligence to polish your dictation",
                      detail: "Until then, Dictation inserts exactly what it hears, with basic punctuation.",
                      action: ("Open Settings", { Permissions.openSettings(.appleIntelligence) }),
                      dismiss: { withAnimation(Motion.fluid) { nudgeDismissed = true } })
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            Spacer()
        }
        .onAppear {
            withAnimation(Motion.gentle.delay(0.1)) { shown = true }
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }
}

private struct StatBlock: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(Theme.Font.display)
                .tracking(Theme.displayTracking)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(Motion.gentle, value: value)
            Text(label).font(Theme.Font.caption).foregroundStyle(Theme.fg(0.45))
        }
    }
}

private struct Nudge: View {
    let title: String
    let detail: String
    var action: (label: String, run: () -> Void)?
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(Theme.Font.body).foregroundStyle(Theme.fg(0.55))
                if let action {
                    Button(action.label, action: action.run)
                        .buttonStyle(MonoButtonStyle(prominent: true))
                        .padding(.top, 8)
                }
            }
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.fg(0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
            .strokeBorder(Theme.fg(0.12), lineWidth: 1))
        .frame(maxWidth: 520)
    }
}
