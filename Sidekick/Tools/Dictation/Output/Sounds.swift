import AppKit

/// Soft start/stop clicks. Honors the "soundsEnabled" setting (on by default).
final class SystemSounds: SoundPlaying {
    static let enabledKey = "soundsEnabled"
    private let defaults: UserDefaults
    private let output: (Sound) -> Void

    init(defaults: UserDefaults = .standard, output: ((Sound) -> Void)? = nil) {
        self.defaults = defaults
        defaults.register(defaults: [Self.enabledKey: true])
        if let output {
            self.output = output
        } else {
            let start = Self.load("start"), stop = Self.load("stop")
            self.output = { sound in
                let s = sound == .start ? start : stop
                s?.stop()
                s?.play()
            }
        }
    }

    func play(_ s: Sound) {
        guard defaults.bool(forKey: Self.enabledKey) else { return }
        output(s)
    }

    private static func load(_ name: String) -> NSSound? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "caf") else { return nil }
        let sound = NSSound(contentsOf: url, byReference: true)
        sound?.volume = 0.35
        return sound
    }
}
