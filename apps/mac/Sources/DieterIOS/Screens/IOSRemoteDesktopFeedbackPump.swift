import DieterAPI
import Foundation

struct IOSRemoteDesktopFeedbackHeartbeat {
    let inputEpoch: Data
    private(set) var sequence: UInt64 = 0

    mutating func next(inputActive: Bool) -> Dieter_V1_RemoteDesktopReceiverFeedback {
        sequence &+= 1
        var value = Dieter_V1_RemoteDesktopReceiverFeedback()
        value.protocolVersion = DieterContract.number
        value.inputEpoch = inputEpoch
        value.sequence = sequence
        value.measurementSequence = 1
        value.inputActive = inputActive
        return value
    }
}

#if os(iOS)
    @preconcurrency import WebRTC

    /// Sends the signed receiver heartbeat independently of rendering and the
    /// MainActor. The host pauses input after three seconds without this proof
    /// of receiver liveness, while leaving video open.
    final class IOSRemoteDesktopFeedbackPump: @unchecked Sendable {
        private let lock = NSLock()
        private let queue = DispatchQueue(label: "dieter.ios.screen.receiver-feedback")
        private var timer: DispatchSourceTimer?
        private var channel: RTCDataChannel?
        private var heartbeat: IOSRemoteDesktopFeedbackHeartbeat?
        private var inputActive = false
        private var generation: UInt64 = 0

        func start(channel: RTCDataChannel?, inputEpoch: Data) {
            lock.withLock {
                timer?.cancel()
                generation &+= 1
                let current = generation
                self.channel = channel
                heartbeat = IOSRemoteDesktopFeedbackHeartbeat(inputEpoch: inputEpoch)
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(25))
                timer.setEventHandler { [weak self] in self?.send(generation: current) }
                self.timer = timer
                timer.resume()
            }
        }

        func input(active: Bool) {
            lock.withLock { inputActive = active }
        }

        func stop() {
            lock.withLock {
                generation &+= 1
                timer?.cancel()
                timer = nil
                channel = nil
                heartbeat = nil
                inputActive = false
            }
        }

        private func send(generation current: UInt64) {
            lock.withLock {
                guard current == generation, let channel, channel.readyState == .open,
                    channel.bufferedAmount < 16_384, var heartbeat
                else { return }
                let value = heartbeat.next(inputActive: inputActive)
                self.heartbeat = heartbeat
                guard let data = try? value.serializedData() else { return }
                _ = channel.sendData(RTCDataBuffer(data: data, isBinary: true))
            }
        }

        deinit { timer?.cancel() }
    }
#endif
