enum Permission: String, CaseIterable, Sendable {
    case microphone, accessibility, speech

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .speech: "Speech Recognition"
        }
    }

    var isGranted: Bool {
        switch self {
        case .microphone: Permissions.microphone
        case .accessibility: Permissions.accessibility
        case .speech: Permissions.speech
        }
    }
}
