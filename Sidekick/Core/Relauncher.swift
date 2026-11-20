import AppKit

enum Relauncher {
    /// Reopens the app after a short delay (some permissions only take effect on a fresh launch), then quits.
    @MainActor static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.5; open \"\(Bundle.main.bundlePath)\""]
        try? process.run()
        NSApp.terminate(nil)
    }
}
