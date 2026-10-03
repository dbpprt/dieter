import DieterAPI
import DieterShared
import DieterTransport
import Foundation

/// The WebRTC control route for the shared core: `ControlRTCBridge` exposes a
/// data channel to one daemon as a loopback port that carries the daemon's own
/// TLS, which the RPC bridge then pins like any direct route.
package final class CoreControlChannels: NSObject, NativeControlChannels, Sendable {
    package func create(configuration: Data, completion: any NativeControlChannelCompletion) {
        let completion = NativeCallback(completion)
        do {
            let parsed = try Dieter_Gateway_V1_RTCConfiguration(serializedBytes: configuration)
            completion.value.completed(
                channel: CoreControlChannel(try ControlRTCBridge(configuration: parsed)), error: nil)
        } catch {
            completion.value.completed(channel: nil, error: error.localizedDescription)
        }
    }
}

private final class CoreControlChannel: NSObject, NativeControlChannel, Sendable {
    private let bridge: NativeCallback<ControlRTCBridge>

    init(_ bridge: ControlRTCBridge) {
        self.bridge = NativeCallback(bridge)
    }

    func offer(completion: any NativeControlOfferCompletion) {
        let completion = NativeCallback(completion)
        let bridge = bridge
        Task {
            do {
                completion.value.completed(sdp: try await bridge.value.offer(), error: nil)
            } catch {
                completion.value.completed(sdp: nil, error: error.localizedDescription)
            }
        }
    }

    func connect(answerSdp: String, completion: any NativeControlConnectCompletion) {
        let completion = NativeCallback(completion)
        let bridge = bridge
        Task {
            do {
                completion.value.completed(port: Int32(try await bridge.value.connect(answer: answerSdp)), error: nil)
            } catch {
                completion.value.completed(port: 0, error: error.localizedDescription)
            }
        }
    }

    func close() { bridge.value.close() }
}
