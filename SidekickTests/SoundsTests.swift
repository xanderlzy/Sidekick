import Testing
import Foundation
@testable import Sidekick

struct SoundsTests {
    @Test func respectsSoundsSetting() {
        let defaults = UserDefaults(suiteName: "sidekick.test.\(UUID())")!
        var played: [Sound] = []
        let sounds = SystemSounds(defaults: defaults) { played.append($0) }
        sounds.play(.start)                       // default is on
        defaults.set(false, forKey: SystemSounds.enabledKey)
        sounds.play(.stop)
        #expect(played == [.start])
    }
}
