import Foundation
import os
import UserNotifications

/// Tells the user when a queued file finishes or fails.
protocol TranscribeNotifier: Sendable {
    func requestPermissionIfNeeded() async
    func finished(title: String)
    func failed(title: String)
}

/// Posts local notifications. If permission was refused, posting fails quietly and nothing else changes.
struct UserNotificationsNotifier: TranscribeNotifier {
    private static let log = Logger(subsystem: "com.sidekick.app", category: "Transcribe")

    func requestPermissionIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
        catch { Self.log.error("Notification permission request failed: \(error)") }
    }

    func finished(title: String) { post("\(title) is transcribed") }
    func failed(title: String) { post("\(title) couldn't be transcribed") }

    private func post(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = text
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Self.log.error("Couldn't post notification: \(error)") }
        }
    }
}

/// Does nothing; for tests and previews.
struct SilentNotifier: TranscribeNotifier {
    func requestPermissionIfNeeded() async {}
    func finished(title: String) {}
    func failed(title: String) {}
}
