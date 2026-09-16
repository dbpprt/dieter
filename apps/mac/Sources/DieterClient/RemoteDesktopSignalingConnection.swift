import DieterCore
import DieterAPI
import Foundation

package final class RemoteDesktopSignalingConnection: @unchecked Sendable {
    package let rpc: any ScreenSignalingRPC
    package let rtcConfiguration: Dieter_Gateway_V1_RTCConfiguration
    package let daemonCertificatePEM: Data
    package let routeLabel: String

    private let connectionTask: Task<Void, Never>
    private let credentialRefreshTask: Task<Void, Never>?

    package init(
        rpc: any ScreenSignalingRPC,
        connectionTask: Task<Void, Never>,
        rtcConfiguration: Dieter_Gateway_V1_RTCConfiguration,
        daemonCertificatePEM: Data,
        routeLabel: String,
        credentialRefreshTask: Task<Void, Never>? = nil
    ) {
        self.rpc = rpc
        self.connectionTask = connectionTask
        self.rtcConfiguration = rtcConfiguration
        self.daemonCertificatePEM = daemonCertificatePEM
        self.routeLabel = routeLabel
        self.credentialRefreshTask = credentialRefreshTask
    }

    package func shutdown() {
        credentialRefreshTask?.cancel()
        connectionTask.cancel()
        rpc.shutdown()
    }

    deinit { credentialRefreshTask?.cancel() }
}
