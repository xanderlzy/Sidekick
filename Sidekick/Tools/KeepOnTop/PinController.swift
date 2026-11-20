import CoreGraphics
import Observation

@MainActor
protocol MirrorPresenting: AnyObject {
    func present()
    func dismiss()
}

@MainActor @Observable
final class PinController {
    private(set) var pins: [WindowInfo] = []
    @ObservationIgnored private var mirrors: [CGWindowID: MirrorPresenting] = [:]
    @ObservationIgnored private let makeMirror: (WindowInfo) -> MirrorPresenting

    init(makeMirror: @escaping (WindowInfo) -> MirrorPresenting) {
        self.makeMirror = makeMirror
    }

    func toggle(_ w: WindowInfo) {
        if mirrors[w.id] != nil {
            unpin(w.id)
        } else {
            let mirror = makeMirror(w)
            mirrors[w.id] = mirror
            pins.append(w)
            mirror.present()
        }
    }

    func unpin(_ id: CGWindowID) {
        guard let mirror = mirrors.removeValue(forKey: id) else { return }
        pins.removeAll { $0.id == id }
        mirror.dismiss()
    }

    func unpinAll() {
        for id in pins.map(\.id) { unpin(id) }
    }
}
