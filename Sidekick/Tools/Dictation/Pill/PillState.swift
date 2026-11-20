enum PillState: Equatable, Sendable {
    case hidden
    case listening(locked: Bool)
    case polishing
    case message(String)
}
