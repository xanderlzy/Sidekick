import AppKit
import CoreMedia
import QuartzCore
import ScreenCaptureKit

/// Streams one window's pixels into a layer with ScreenCaptureKit.
@MainActor
final class MirrorStream {
    let layer = CALayer()
    private let windowID: CGWindowID
    private let size: CGSize
    private let onStop: () -> Void
    private var stream: SCStream?
    private var sink: FrameSink?
    private var stopped = false

    /// `size` is the source window's size in points; `scale` its screen's backing scale factor.
    init(windowID: CGWindowID, size: CGSize, scale: CGFloat, onStop: @escaping () -> Void) {
        self.windowID = windowID
        self.size = CGSize(width: size.width * scale, height: size.height * scale)
        self.onStop = onStop
        layer.contentsGravity = .resizeAspect
    }

    func start() {
        Task { await begin() }
    }

    func stop() {
        stopped = true
        guard let stream else { return }
        self.stream = nil
        sink = nil
        Task { try? await stream.stopCapture() }
    }

    private func begin() async {
        do {
            let content = try await SCShareableContent.current
            guard !stopped, let window = content.windows.first(where: { $0.windowID == windowID }) else {
                if !stopped { onStop() }
                return
            }
            let config = SCStreamConfiguration()
            config.width = Int(size.width)
            config.height = Int(size.height)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.showsCursor = false
            config.pixelFormat = kCVPixelFormatType_32BGRA

            let sink = FrameSink(
                onFrame: { [weak self] frame in self?.layer.contents = frame.surface },
                onError: { [weak self] in self?.failed() })
            let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window),
                                  configuration: config, delegate: sink)
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            self.sink = sink
            self.stream = stream
            try await stream.startCapture()
            if stopped { try? await stream.stopCapture() }
        } catch {
            failed()
        }
    }

    private func failed() {
        guard !stopped else { return }
        stopped = true
        stream = nil
        sink = nil
        onStop()
    }
}

/// An IOSurface handed from the capture queue to the main actor; it's only read there.
private struct Frame: @unchecked Sendable {
    let surface: IOSurface
}

/// Receives ScreenCaptureKit callbacks off the main actor and forwards complete frames to it.
private final class FrameSink: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    let queue = DispatchQueue(label: "com.sidekick.app.mirror")
    private let onFrame: @MainActor @Sendable (Frame) -> Void
    private let onError: @MainActor @Sendable () -> Void

    init(onFrame: @escaping @MainActor @Sendable (Frame) -> Void,
         onError: @escaping @MainActor @Sendable () -> Void) {
        self.onFrame = onFrame
        self.onError = onError
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue()
        else { return }
        let frame = Frame(surface: surface)
        let onFrame = onFrame
        DispatchQueue.main.async { onFrame(frame) }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let onError = onError
        DispatchQueue.main.async { onError() }
    }
}
