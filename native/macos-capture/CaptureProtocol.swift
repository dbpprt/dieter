import AppKit
import CoreGraphics
import Foundation

struct StreamConfiguration: Codable, Equatable {
    var displayId: String = "primary"
    var maxWidth: Int = 3840
    var maxHeight: Int = 2160
    var fps: Int = 60
    var bitrateKbps: Int = 12000
    var embeddedCursor: Bool = false

    func validate() throws {
        guard (320...3840).contains(maxWidth), (180...2160).contains(maxHeight),
            (1...60).contains(fps), (100...100000).contains(bitrateKbps), displayId.utf8.count <= 64
        else { throw CaptureError.invalidArgument("stream configuration") }
    }
}

struct NativeInput: Codable {
    var kind: String = ""
    var x: Int32 = 0
    var y: Int32 = 0
    var button: Int32 = 0
    var down: Bool = false
    var `repeat`: Bool = false
    var clickCount: Int32 = 0
    var deltaX: Double = 0
    var deltaY: Double = 0
    var precise: Bool = false
    var phase: UInt32 = 0
    var momentumPhase: UInt32 = 0
    var keyCode: UInt32 = 0
    var physicalKey: UInt32 = 0
    var modifiers: UInt32 = 0
    var text: String = ""
    var generation: UInt64 = 0
    var ordinal: UInt64 = 0
}

struct NativeCommand: Decodable {
    let version: Int
    let id: UInt64
    let kind: String
    let input: NativeInput?
    let configuration: StreamConfiguration?
    let frameId: UInt64?
    let streamId: UInt64?
    let profile: String?
}

struct NativeCursor: Encodable {
    var shapeId: String
    var png: Data?
    var hotspotX: Double
    var hotspotY: Double
    var width: Double
    var height: Double
    var normalizedX: Int32
    var normalizedY: Int32
    var visible: Bool
    var displayGeneration: UInt64
    var lastInputOrdinal: UInt64
}

struct NativeState: Encodable {
    var width: Int
    var height: Int
    var fps: Int
    var bitrateKbps: Int
    var displayId: String
    var displayGeneration: UInt64
    var encoder: String
    var embeddedCursor: Bool
}

struct NativeEvent: Encodable {
    var version = 2
    var streamId: UInt64 = 0
    var ack: UInt64 = 0
    var error: String?
    var cursor: NativeCursor?
    var state: NativeState?
}

// A separate bounded descriptor prevents screen payloads from holding up input
// acknowledgments. Every write has a deadline, including when the daemon dies.
final class EventWriter: @unchecked Sendable {
    private let fd: Int32
    private static let sharedLock = NSLock()
    private let encoder = JSONEncoder()
    private let streamID: UInt64
    init(fd: Int32, streamID: UInt64 = 0) {
        self.fd = fd
        self.streamID = streamID
        encoder.keyEncodingStrategy = .convertToSnakeCase
        if fd >= 0 { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
    }
    @discardableResult func send(_ event: NativeEvent) -> Bool {
        guard fd >= 0 else { return true }
        Self.sharedLock.lock()
        defer { Self.sharedLock.unlock() }
        var tagged = event
        tagged.streamId = streamID == 0 ? event.streamId : streamID
        guard var data = try? encoder.encode(tagged), data.count <= 350000 else { return false }
        data.append(10)
        return data.withUnsafeBytes { bytes in
            var offset = 0
            let deadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                guard errno == EAGAIN || errno == EINTR, DispatchTime.now().uptimeNanoseconds < deadline else {
                    return false
                }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&descriptor, 1, 10)
            }
            return true
        }
    }
}

struct NativeDisplay: Encodable, Equatable {
    var id: String
    var name: String
    var logicalWidth: Int
    var logicalHeight: Int
    var physicalWidth: Int
    var physicalHeight: Int
    var scale: Double
    var rotation: Int
    var primary: Bool
    var originX: Int
    var originY: Int
    var refreshRate: Double
}

func nativeDisplays() -> [NativeDisplay] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).map { id in
        let rect = CGDisplayBounds(id)
        let mode = CGDisplayCopyDisplayMode(id)
        return NativeDisplay(
            id: String(id), name: CGDisplayIsMain(id) != 0 ? "Main display" : "Display \(id)",
            logicalWidth: Int(rect.width), logicalHeight: Int(rect.height),
            physicalWidth: mode?.pixelWidth ?? Int(rect.width), physicalHeight: mode?.pixelHeight ?? Int(rect.height),
            scale: Double(mode?.pixelWidth ?? Int(rect.width)) / max(1, rect.width),
            rotation: Int(CGDisplayRotation(id)), primary: CGDisplayIsMain(id) != 0,
            originX: Int(rect.minX), originY: Int(rect.minY), refreshRate: mode?.refreshRate ?? 60)
    }
}

// ScreenCaptureKit reconfiguration suspends. Serialize those operations across
// command, display topology, and cursor fallback tasks with a bounded wait list.
actor ConfigurationGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var closed = false
    private var shutdownWaiter: CheckedContinuation<Void, Never>?
    func acquire() async throws {
        guard !closed else { throw CaptureError.invalidArgument("capture stopped") }
        if !busy {
            busy = true
            return
        }
        guard waiters.count < 8 else { throw CaptureError.invalidArgument("too many capture updates") }
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }
    func release() {
        if let waiter = shutdownWaiter {
            shutdownWaiter = nil
            waiter.resume()
            return
        }
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
    // Let the current configuration finish, reject queued/future updates, and
    // give teardown exclusive ownership of the capture and hardware encoder.
    func shutdown() async {
        closed = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(throwing: CaptureError.invalidArgument("capture stopped")) }
        if busy {
            await withCheckedContinuation { shutdownWaiter = $0 }
        }
    }
}

// One worker per bounded lane preserves command order without blocking the IPC
// reader. Configuration may suspend in ScreenCaptureKit; input and frame credits
// use independent lanes, and heartbeat replies never enter either lane.
final class NativeCommandQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var pending: [() async -> Void] = []
    private var running = false
    private var closed = false
    init(capacity: Int) { self.capacity = capacity }
    func submit(_ operation: @escaping () async -> Void) -> Bool {
        let accepted = lock.withLock { () -> Bool in
            guard !closed, pending.count + (running ? 1 : 0) < capacity else { return false }
            pending.append(operation)
            if !running {
                running = true
                Task { await self.drain() }
            }
            return true
        }
        return accepted
    }
    private func drain() async {
        while let operation = next() { await operation() }
    }
    private func next() -> (() async -> Void)? {
        lock.withLock {
            if pending.isEmpty { running = false; return nil }
            return pending.removeFirst()
        }
    }
    func close() {
        lock.withLock {
            closed = true; pending.removeAll()
        }
    }
}
