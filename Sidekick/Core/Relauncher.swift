import AppKit

enum Relauncher {
    /// Reopens the app once this process has exited (some permissions only take effect on a fresh launch), then quits.
    /// Quits only if the helper actually started.
    @MainActor static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \"$2\" 2>/dev/null; do sleep 0.1; done; open \"$1\"",
                             "sh", Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier)]
        guard (try? process.run()) != nil else { return }
        NSApp.terminate(nil)
    }
}
