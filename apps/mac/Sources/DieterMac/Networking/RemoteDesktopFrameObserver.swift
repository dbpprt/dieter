import Foundation
@preconcurrency import WebRTC

// Observe frame identity without copying pixels or updating SwiftUI each frame.
// Control is armed only after presenting a frame from the advertised display.
final class RemoteDesktopFrameObserver: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var latest: UInt32?
    private var expected: (token: UInt64, generation: UInt64, timestamp: UInt32)?
    private var delivered: (UInt64, UInt64)?
    var onReady: (@Sendable (UInt64, UInt64) -> Void)?

    func reset() {
        lock.lock(); latest = nil; expected = nil; delivered = nil; lock.unlock()
    }
    func expect(token: UInt64, generation: UInt64, timestamp: UInt32) {
        lock.lock()
        expected = (token, generation, timestamp)
        let ready = readyLocked()
        lock.unlock()
        if let ready { onReady?(ready.0, ready.1) }
    }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.lock()
        latest = UInt32(bitPattern: frame.timeStamp)
        let ready = readyLocked()
        lock.unlock()
        if let ready { onReady?(ready.0, ready.1) }
    }
    private func readyLocked() -> (UInt64, UInt64)? {
        guard let expected, let latest,
            Int32(bitPattern: latest &- expected.timestamp) >= 0,
            delivered?.0 != expected.token || delivered?.1 != expected.generation
        else { return nil }
        delivered = (expected.token, expected.generation)
        return delivered
    }
}
