import AppKit
import AVFoundation
import ApplicationServices
import Speech

enum PermissionError: Error { case microphone, accessibility }

enum Permissions {
    enum Pane {
        case microphone, accessibility, keyboard, appleIntelligence, desktopAndDock, systemAudio

        var url: URL {
            switch self {
            case .microphone: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .systemAudio: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
            case .keyboard: URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
            case .appleIntelligence: URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!
            case .desktopAndDock: URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!
            }
        }
    }

    static var microphone: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var speech: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    /// Cached verdict only; never probes Core Audio. The probe runs from the setup step's button.
    @MainActor static var systemAudio: Bool { SystemAudioPermission.cached == .granted }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Shows the system prompt that adds Sidekick to the Accessibility list.
    static func promptAccessibility() {
        let key = "AXTrustedCheckOptionPrompt"  // kAXTrustedCheckOptionPrompt
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @MainActor static func openSettings(_ pane: Pane) {
        NSWorkspace.shared.open(pane.url)
    }
}
