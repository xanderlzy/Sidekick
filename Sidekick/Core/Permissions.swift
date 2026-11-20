import AppKit
import AVFoundation
import ApplicationServices
import Speech

enum PermissionError: Error { case microphone, accessibility }

enum Permissions {
    enum Pane {
        case screenRecording, microphone, accessibility, keyboard, appleIntelligence

        var url: URL {
            switch self {
            case .screenRecording: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            case .microphone: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .keyboard: URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
            case .appleIntelligence: URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!
            }
        }
    }

    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static var microphone: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var speech: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    /// Shows the system prompt for Screen Recording (no-op if already decided).
    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

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
