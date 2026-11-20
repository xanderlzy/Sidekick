import Combine
import SwiftUI

struct DictationSettingsView: View {
    let env: DictationEnvironment
    @AppStorage("hotkey") private var hotkey = HotkeyKey.fn.rawValue
    @AppStorage("inputDeviceUID") private var inputDeviceUID = ""
    @AppStorage(SystemSounds.enabledKey) private var soundsEnabled = true
    @AppStorage(RetentionPolicy.storageKey) private var retention = RetentionPolicy.default.rawValue
    @State private var devices = AudioCapture.inputDevices()
    @State private var micGranted = Permissions.microphone
    @State private var axGranted = Permissions.accessibility
    private let permissionPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Dictation Settings").font(Theme.Font.title)

                SettingsSection("Dictation") {
                    SettingsRow(title: "Dictation key", detail: "Hold to talk. Double-tap for hands-free.") {
                        Picker("", selection: $hotkey) {
                            ForEach(HotkeyKey.allCases) { Text($0.displayName).tag($0.rawValue) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    SettingsRow(title: "Microphone") {
                        Picker("", selection: $inputDeviceUID) {
                            Text("System default").tag("")
                            ForEach(devices) { Text($0.name).tag($0.uid) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    EngineSettings(env: env)
                }

                SettingsSection("Feedback") {
                    SettingsRow(title: "Sounds", detail: "A soft click when listening starts and stops.") {
                        Toggle("", isOn: $soundsEnabled).toggleStyle(MonoToggleStyle()).labelsHidden()
                    }
                }

                SettingsSection("History") {
                    SettingsRow(title: "Keep history", detail: "Stored only on this Mac. Stats are kept either way.") {
                        Picker("", selection: $retention) {
                            ForEach(RetentionPolicy.allCases) { Text($0.displayName).tag($0.rawValue) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }

                SettingsSection("Permissions") {
                    SettingsRow(title: "Microphone", detail: "To hear you while the key is held.") {
                        PermissionControl(granted: micGranted) {
                            Task {
                                if await !Permissions.requestMicrophone() { Permissions.openSettings(.microphone) }
                            }
                        }
                    }
                    SettingsRow(title: "Accessibility", detail: "To notice the dictation key and paste text.") {
                        PermissionControl(granted: axGranted) {
                            Permissions.promptAccessibility()
                            Permissions.openSettings(.accessibility)
                        }
                    }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
        .scrollIndicators(.never)
        .onChange(of: hotkey) { _, new in env.setHotkey(HotkeyKey(rawValue: new) ?? .fn) }
        .onChange(of: inputDeviceUID) { _, new in env.audio.deviceUID = new.isEmpty ? nil : new }
        .onChange(of: retention) { _, _ in env.history.prune() }
        .onReceive(permissionPoll) { _ in
            micGranted = Permissions.microphone
            axGranted = Permissions.accessibility
        }
        .onAppear { devices = AudioCapture.inputDevices() }
    }
}

/// Speech engine choice, plus the optional Whisper download.
struct EngineSettings: View {
    let env: DictationEnvironment
    @AppStorage(TranscriberKind.storageKey) private var engine = TranscriberKind.apple.rawValue

    private var store: WhisperModelStore { env.whisperModel }
    private var waitingForDownload: Bool { engine == TranscriberKind.whisper.rawValue && !store.isReady }

    var body: some View {
        SettingsRow(title: "Speech engine",
                    detail: waitingForDownload ? "Using Apple until Whisper is downloaded." : "Runs entirely on this Mac.") {
            Picker("", selection: $engine) {
                ForEach(TranscriberKind.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .labelsHidden().fixedSize()
        }
        .onChange(of: engine) { _, _ in env.warmUpEngine() }
        .onChange(of: store.state) { _, new in if new == .ready { env.warmUpEngine() } }

        SettingsRow(title: "Whisper model", detail: whisperDetail) {
            switch store.state {
            case .notDownloaded, .failed:
                Button("Download") { store.download() }.buttonStyle(MonoButtonStyle(prominent: true))
            case .downloading(let fraction):
                HStack(spacing: 10) {
                    ProgressBar(fraction: fraction).frame(width: 120)
                    Text("\(Int(fraction * 100))%").font(Theme.Font.caption).monospacedDigit()
                        .foregroundStyle(Theme.fg(0.5)).frame(width: 34, alignment: .trailing)
                }
            case .ready:
                Button("Remove") { store.remove(); env.warmUpEngine() }.buttonStyle(MonoButtonStyle())
            }
        }
        .animation(Motion.fluid, value: store.state)
    }

    private var whisperDetail: String {
        switch store.state {
        case .notDownloaded: "Optional. Often better with accents and jargon. A few hundred MB."
        case .downloading: "Downloading…"
        case .ready: "Downloaded and ready."
        case .failed(let message): message
        }
    }
}

/// Thin ink progress bar.
struct ProgressBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fg(0.12))
                Capsule().fill(Theme.fg()).frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
                    .animation(Motion.snappy, value: fraction)
            }
        }
        .frame(height: 4)
    }
}
