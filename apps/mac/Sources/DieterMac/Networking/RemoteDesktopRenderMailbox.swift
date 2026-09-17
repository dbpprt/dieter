import CoreVideo
import Foundation
import QuartzCore
@preconcurrency import WebRTC

final class RemoteDesktopMetalSubmission: @unchecked Sendable {
    let frame: RTCVideoFrame
    let textures: [CVMetalTexture]
    let token: UInt64
    init(frame: RTCVideoFrame, textures: [CVMetalTexture], token: UInt64) {
        self.frame = frame; self.textures = textures; self.token = token
    }
}

struct RemoteDesktopPresentation: @unchecked Sendable {
    let frame: RTCVideoFrame
    let presentedAt: Double
}

struct RemoteDesktopRenderSnapshot: @unchecked Sendable {
    var token: UInt64 = 0
    var framesPresented: UInt64 = 0
    var drawSubmissions: UInt64 = 0
    var totalRenderMilliseconds: Double = 0
    var timedPresentations: UInt64 = 0
    var latePresentations: UInt64 = 0
    var lastTimestamp: Int32?
    var lastTimedTimestamp: Int32?
    var lastPixelFormat: OSType = 0
    var size = CGSize.zero
    var failure: String?
    var presentation: RemoteDesktopPresentation?
}

// Presentation metrics advance on the hardware callback even while MainActor
// is busy. UI notifications coalesce to one task and the newest presentation.
final class RemoteDesktopRenderStatistics: @unchecked Sendable {
    private let lock = NSLock()
    private var value = RemoteDesktopRenderSnapshot()
    private var uiScheduled = false
    var snapshot: RemoteDesktopRenderSnapshot { lock.withLock { value } }
    func update(token: UInt64, _ body: (inout RemoteDesktopRenderSnapshot) -> Void) -> Bool {
        lock.withLock {
            guard value.token == token else { return false }
            body(&value)
            if uiScheduled { return false }
            uiScheduled = true
            return true
        }
    }
    func consume() -> RemoteDesktopRenderSnapshot {
        lock.withLock {
            let result = value
            value.presentation = nil; value.failure = nil
            uiScheduled = false
            return result
        }
    }
    func reset(token: UInt64) {
        lock.withLock { value = RemoteDesktopRenderSnapshot(token: token) }
    }
}

// One GPU submission plus one replaceable decoded frame. Reset invalidates
// decoder callbacks but keeps the outstanding draw's completion responsible for
// handing off ownership. Otherwise a reset could start overlapping GPU work.
final class RemoteDesktopRenderMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: RTCVideoFrame?
    private var arrivedAt: Double = 0
    private var busy = false
    private var closed = false
    private var token: UInt64 = 0
    var hasPending: Bool { lock.withLock { pending != nil } }
    var currentToken: UInt64 { lock.withLock { token } }
    func offer(_ frame: RTCVideoFrame, expectedToken: UInt64? = nil) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            if let expectedToken, expectedToken != token { return false }
            pending = frame; arrivedAt = CACurrentMediaTime()
            if busy { return false }
            busy = true
            return true
        }
    }
    func take() -> (RTCVideoFrame, UInt64, Double)? {
        lock.withLock {
            guard let pending else { return nil }
            self.pending = nil
            return (pending, token, arrivedAt)
        }
    }
    func complete() -> Bool {
        lock.withLock {
            if pending != nil { return true }
            busy = false
            return false
        }
    }
    @discardableResult func reset() -> UInt64 {
        lock.withLock {
            token &+= 1; pending = nil; return token
        }
    }
    func close() {
        lock.withLock {
            closed = true; token &+= 1; pending = nil
        }
    }
    func isCurrent(_ token: UInt64) -> Bool { lock.withLock { !closed && token == self.token } }
}
