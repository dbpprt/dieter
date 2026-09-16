import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

// One ScreenCaptureKit stream per physical display. Surfaces stay in the native
// process and feed the bounded, independent VideoToolbox rendition mailboxes.
actor SharedDisplayPool {
    static let shared = SharedDisplayPool()
    private let gate = ConfigurationGate()
    private var displays: [CGDirectDisplayID: SharedDisplayCapture] = [:]

    func add(
        display: SCDisplay, id: UInt64, width: Int, height: Int, fps: Int, cursor: Bool,
        receive: @escaping (CapturedFrame) -> Void, cursorChanged: @escaping (Bool) -> Void,
        failed: @escaping (Error) -> Void
    ) async throws {
        try await gate.acquire()
        do {
            let capture = displays[display.displayID] ?? SharedDisplayCapture(display: display)
            displays[display.displayID] = capture
            try await capture.add(
                id: id,
                consumer: .init(
                    width: width, height: height, fps: fps, cursor: cursor,
                    receive: receive, cursorChanged: cursorChanged, failed: failed))
            await gate.release()
        } catch {
            if let capture = displays[display.displayID] {
                await capture.remove(id: id)
                if capture.empty { displays.removeValue(forKey: display.displayID) }
            }
            await gate.release()
            throw error
        }
    }
    func update(display: CGDirectDisplayID, id: UInt64, width: Int, height: Int, fps: Int, cursor: Bool) async throws {
        try await gate.acquire()
        do {
            try await displays[display]?.update(id: id, width: width, height: height, fps: fps, cursor: cursor)
            await gate.release()
        } catch { await gate.release(); throw error }
    }
    func remove(display: CGDirectDisplayID, id: UInt64) async {
        do { try await gate.acquire() } catch { return }
        if let capture = displays[display] {
            await capture.remove(id: id)
            if capture.empty { displays.removeValue(forKey: display) }
        }
        await gate.release()
    }
}

private final class SharedDisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Consumer {
        var width: Int
        var height: Int
        var fps: Int
        var cursor: Bool
        let receive: (CapturedFrame) -> Void
        let cursorChanged: (Bool) -> Void
        let failed: (Error) -> Void
    }
    private let display: SCDisplay
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.dbpprt.dieter.capture.display", qos: .userInteractive)
    private var consumers: [UInt64: Consumer] = [:]
    private var stream: SCStream?
    private var applied: [Int] = []
    init(display: SCDisplay) { self.display = display }
    var empty: Bool { lock.withLock { consumers.isEmpty } }
    func add(id: UInt64, consumer: Consumer) async throws {
        lock.withLock { consumers[id] = consumer }
        try await configure()
    }
    func update(id: UInt64, width: Int, height: Int, fps: Int, cursor: Bool) async throws {
        lock.withLock {
            guard var value = consumers[id] else { return }
            value.width = width; value.height = height; value.fps = fps; value.cursor = cursor
            consumers[id] = value
        }
        try await configure()
    }
    func remove(id: UInt64) async {
        _ = lock.withLock { consumers.removeValue(forKey: id) }
        if empty {
            let old = stream; stream = nil
            try? await old?.stopCapture()
        } else {
            try? await configure()
        }
    }
    private func configure() async throws {
        let current = lock.withLock { Array(consumers.values) }
        guard !current.isEmpty else { return }
        let width = current.map(\.width).max()!, height = current.map(\.height).max()!
        let fps = current.map(\.fps).max()!, cursor = current.contains { $0.cursor }
        let desired = [width, height, fps, cursor ? 1 : 0]
        if desired != applied {
            let config = SCStreamConfiguration()
            config.width = width; config.height = height
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.queueDepth = 3; config.showsCursor = cursor
            config.capturesAudio = false; config.scalesToFit = true; config.colorSpaceName = CGColorSpace.sRGB
            if let stream {
                try await stream.updateConfiguration(config)
            } else {
                let next = SCStream(
                    filter: SCContentFilter(display: display, excludingWindows: []), configuration: config,
                    delegate: self)
                try next.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                stream = next
                do { try await next.startCapture() } catch { stream = nil; throw error }
            }
            applied = desired
        }
        current.forEach { $0.cursorChanged(cursor) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { Array(consumers.values) }.forEach { $0.failed(error) }
    }
    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen, CMSampleBufferIsValid(sampleBuffer),
            CMSampleBufferGetImageBuffer(sampleBuffer) != nil
        else { return }
        if let values = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let raw = values.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw),
            status != .complete && status != .started
        {
            return
        }
        let frame = CapturedFrame(
            sampleBuffer: sampleBuffer,
            capturedAtNanoseconds: Int64(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds * 1_000_000_000))
        lock.withLock { Array(consumers.values) }.forEach { $0.receive(frame) }
    }
}
