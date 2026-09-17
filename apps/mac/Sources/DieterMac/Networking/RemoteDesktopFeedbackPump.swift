import DieterAPI
import Foundation
@preconcurrency import WebRTC

/// A small locked sender owns its timer independently of MainActor and getStats.
/// stop() serializes with sends before the controller closes the native channel.
final class RemoteDesktopFeedbackPump: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dieter.screen.receiver-feedback")
    private var timer: DispatchSourceTimer?
    private var channel: RTCDataChannel?
    private var feedback = Dieter_V1_RemoteDesktopReceiverFeedback()
    private var references: [Dieter_V1_RemoteDesktopReference] = []
    private var sequence: UInt64 = 0
    private var generation: UInt64 = 0
    private var measurementSequence: UInt64 = 1
    private var measuredAt: TimeInterval = 0
    private let clock: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private let sendFeedback: (@Sendable (Dieter_V1_RemoteDesktopReceiverFeedback) -> Void)?

    init(sendFeedback: (@Sendable (Dieter_V1_RemoteDesktopReceiverFeedback) -> Void)? = nil) {
        self.sendFeedback = sendFeedback
    }
    private var inputActive = false
    private var inputUpdatedAt: TimeInterval = 0

    func start(channel: RTCDataChannel?, initial: Dieter_V1_RemoteDesktopReceiverFeedback) {
        lock.withLock {
            timer?.cancel()
            generation &+= 1
            let current = generation
            self.channel = channel
            feedback = initial
            references.removeAll()
            sequence = 0
            measurementSequence = 1
            measuredAt = clock()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(25))
            timer.setEventHandler { [weak self] in self?.send(generation: current) }
            self.timer = timer
            timer.resume()
        }
    }

    func update(_ value: Dieter_V1_RemoteDesktopReceiverFeedback, measuredAt: TimeInterval? = nil) {
        lock.withLock {
            feedback = value
            measurementSequence &+= 1
            self.measuredAt = measuredAt ?? clock()
        }
    }

    func acknowledge(_ values: [Dieter_V1_RemoteDesktopReference]) {
        let current = lock.withLock { () -> UInt64 in
            references = Array((references + values).suffix(8))
            return generation
        }
        queue.async { [weak self] in self?.send(generation: current) }
    }

    func input(active: Bool) {
        lock.withLock {
            inputActive = active
            inputUpdatedAt = clock()
        }
    }

    func stop() {
        lock.withLock {
            generation &+= 1; timer?.cancel(); timer = nil; channel = nil; inputActive = false; references.removeAll()
        }
    }

    private func send(generation current: UInt64) {
        lock.withLock {
            guard current == generation else { return }
            if sendFeedback == nil {
                guard let channel, channel.readyState == .open, channel.bufferedAmount < 16_384 else { return }
            }
            sequence &+= 1
            var value = feedback
            value.sequence = sequence
            value.decodedReferences = references
            value.measurementSequence = measurementSequence
            value.measurementAgeMs = UInt32(min(Double(UInt32.max), max(0, (clock() - measuredAt) * 1000)))
            value.inputActive = inputActive && clock() - inputUpdatedAt < 1
            if let sendFeedback { sendFeedback(value); return }
            guard let channel, let raw = try? value.serializedData() else { return }
            _ = channel.sendData(RTCDataBuffer(data: raw, isBinary: true))
        }
    }

    deinit { timer?.cancel() }
}
