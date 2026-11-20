enum Permission: String, CaseIterable, Sendable {
    case screenRecording, microphone, accessibility, speech

    var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .speech: "Speech Recognition"
        }
    }

    var isGranted: Bool {
        switch self {
        case .screenRecording: Permissions.screenRecording
        case .microphone: Permissions.microphone
        case .accessibility: Permissions.accessibility
        case .speech: Permissions.speech
        }
    }
}
