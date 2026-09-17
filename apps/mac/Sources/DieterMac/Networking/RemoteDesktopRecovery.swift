import DieterAPI
import DieterCore
import Foundation
import SwiftProtobuf

struct RemoteDesktopRecovery {
    private var attempts = 0
    private var streamingSince: TimeInterval?

    mutating func streaming(now: TimeInterval) {
        if streamingSince == nil { streamingSince = now }
    }

    mutating func nextDelay(now: TimeInterval) -> Double? {
        if let streamingSince, now - streamingSince >= 10 { attempts = 0 }
        streamingSince = nil
        guard attempts < 3 else { return nil }
        let delay = Double(1 << attempts)
        attempts += 1
        return delay
    }

    static func retryableClosure(_ reason: String) -> Bool {
        ["session lease expired", "signaling observer did not reconnect", "WebRTC peer did not reconnect",
         "peer connection failed", "peer connection closed", "daemon shutdown",
         "native capture rendition stopped", "native daemon heartbeat expired",
         "native capture helper unresponsive", "native capture helper stopped"].contains(reason)
    }
}

enum RemoteDesktopLeaseRenewal {
    // UI stalls must not delay the legacy/authenticated RPC heartbeat. The
    // failure callback dispatches UI work without blocking this sender.
    static func start(
        rpc: any ScreenSignalingRPC, sessionID: String, clock: ClientClock = .live,
        interval: Duration = .seconds(5), onFailure: @escaping @Sendable (String) -> Void
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            var signal = Dieter_V1_RemoteDesktopSignal()
            signal.sessionID = sessionID; signal.leaseHeartbeat = Google_Protobuf_Empty()
            while !Task.isCancelled {
                do {
                    try await clock.sleep(interval)
                    try Task.checkCancellation()
                    try await rpc.sendRemoteDesktopSignal(signal)
                } catch {
                    guard !Task.isCancelled else { return }
                    onFailure(DieterRPCFailure.message(for: error))
                }
            }
        }
    }
}
