import CoreAudio
import Foundation

/// One Core Audio process object, as a plain value. `outputDevices` is empty when none is reported.
struct AudioProcess: Equatable, Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isRunningOutput: Bool
    let outputDevices: [AudioObjectID]

    init(objectID: AudioObjectID, pid: pid_t, bundleID: String?, isRunningOutput: Bool,
         outputDevices: [AudioObjectID] = []) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningOutput = isRunningOutput
        self.outputDevices = outputDevices
    }
}

struct RunningApp: Equatable, Sendable {
    let pid: pid_t
    let bundleID: String
    let name: String
    /// True when the app's activation policy is `.regular` (a real, Dock-visible app).
    let isRegular: Bool

    init(pid: pid_t, bundleID: String, name: String, isRegular: Bool = true) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.isRegular = isRegular
    }
}

/// Maps Core Audio processes onto the apps that own them. Pure; no Core Audio calls.
enum AppGrouping {
    static let webContentKey = "webkit.webcontent"
    private static let webKitBundleIDs: Set<String> = ["com.apple.WebKit.GPU", "com.apple.WebKit.WebContent"]
    private static let maxDepth = 16

    static func group(
        processes: [AudioProcess],
        apps: [RunningApp],
        ownBundleID: String,
        parentOf: (pid_t) -> pid_t?
    ) -> [String: [AudioProcess]] {
        let others = apps.filter { $0.bundleID != ownBundleID }
        // Some helpers are listed as running apps themselves (Chrome's audio service, "Google Chrome
        // Helper (Aperitif)", is com.google.Chrome.helper). A non-regular (background) app whose bundle
        // ID extends another running app's is that app's helper, so it never owns a row: its processes
        // fold into the parent. Regular apps (Chrome Canary, Safari web apps) always keep their own row.
        let parents = Set(others.map(\.bundleID))
        let candidates = others.filter { app in
            app.isRegular || !parents.contains { app.bundleID.hasPrefix($0 + ".") }
        }
        var result: [String: [AudioProcess]] = [:]
        for process in processes {
            let bundle = process.bundleID ?? ""
            if !bundle.isEmpty, bundle == ownBundleID || bundle.hasPrefix(ownBundleID + ".") { continue }
            if let key = owner(of: process, bundle: bundle, in: candidates, parentOf: parentOf) {
                result[key, default: []].append(process)
            }
        }
        return result
    }

    private static func owner(
        of process: AudioProcess, bundle: String, in apps: [RunningApp], parentOf: (pid_t) -> pid_t?
    ) -> String? {
        if !bundle.isEmpty {
            if let app = apps.first(where: { $0.bundleID == bundle }) { return app.bundleID }
            // Longest matching prefix wins; the trailing dot stops "Chrome" claiming "Chromecast".
            let prefixed = apps.filter { bundle.hasPrefix($0.bundleID + ".") }
                .max { $0.bundleID.count < $1.bundleID.count }
            if let app = prefixed { return app.bundleID }
        }
        var visited: Set<pid_t> = [process.pid]
        var current = process.pid
        for _ in 0..<maxDepth {
            if let app = apps.first(where: { $0.pid == current }) { return app.bundleID }
            guard let parent = parentOf(current), parent > 0, visited.insert(parent).inserted else { break }
            current = parent
        }
        // Check the last ancestor reached too.
        if let app = apps.first(where: { $0.pid == current }) { return app.bundleID }
        return webKitBundleIDs.contains(bundle) ? webContentKey : nil
    }
}
