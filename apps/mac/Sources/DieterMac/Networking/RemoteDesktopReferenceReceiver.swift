import DieterAPI
import Foundation
@preconcurrency import WebRTC

let remoteDesktopGenericDescriptorURI = "http://www.webrtc.org/experiments/rtp-hdrext/generic-frame-descriptor-00"

// These are decoder completions, never packet arrivals or delayed UI callbacks.
// The reliable challenge and video can arrive in either order. Both histories
// are small, expire in two seconds, and belong to exactly one peer connection.
final class RemoteDesktopReferenceReceiver: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var decoded: [(UInt32, TimeInterval)] = []
    private var pending: [(Dieter_V1_RemoteDesktopReference, TimeInterval)] = []
    private var generation: UInt64 = 0
    private let acknowledge: @Sendable ([Dieter_V1_RemoteDesktopReference]) -> Void
    private let clock: @Sendable () -> TimeInterval
    init(
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        acknowledge: @escaping @Sendable ([Dieter_V1_RemoteDesktopReference]) -> Void
    ) {
        self.clock = clock; self.acknowledge = acknowledge
    }
    func stop() {
        lock.withLock {
            active = false; decoded.removeAll(); pending.removeAll()
        }
    }
    func decoded(timestamp: UInt32) {
        lock.withLock {
            guard active else { return }
            let now = clock()
            decoded.removeAll { now - $0.1 >= 2 }
            if decoded.count >= 128 { decoded.removeFirst() }
            decoded.append((timestamp, now)); deliver(now: now)
        }
    }
    func expect(_ value: Dieter_V1_RemoteDesktopReference) {
        lock.withLock {
            guard active, value.frameID > 0, value.generation > 0, value.generation >= generation else { return }
            if value.generation > generation { pending.removeAll(); generation = value.generation }
            if pending.count >= 8 { pending.removeFirst() }
            pending.append((value, clock())); deliver(now: clock())
        }
    }
    private func deliver(now: TimeInterval) {
        var ready: [Dieter_V1_RemoteDesktopReference] = []
        pending.removeAll { value, at in
            if now - at >= 2 { return true }
            if decoded.contains(where: { $0.0 == value.rtpTimestamp && now - $0.1 < 2 }) {
                ready.append(value); return true
            }
            return false
        }
        if !ready.isEmpty { acknowledge(ready) }
    }
}

func remoteDesktopEnableReferenceDependencies(_ transceiver: RTCRtpTransceiver) throws -> Bool {
    let extensions = transceiver.headerExtensionsToNegotiate
    guard let descriptor = extensions.first(where: { $0.uri == remoteDesktopGenericDescriptorURI }) else {
        return false
    }
    descriptor.direction = .recvOnly
    try transceiver.setHeaderExtensionsToNegotiate(extensions)
    return true
}
