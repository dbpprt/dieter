import DieterAPI
import Foundation

final class RemoteDesktopSignalingConnection: @unchecked Sendable {
  let rpc: DieterRPC
  let rtcConfiguration: Dieter_Gateway_V1_RTCConfiguration
  let daemonCertificatePEM: Data
  let routeLabel: String

  private let connectionTask: Task<Void, Never>

  init(
    rpc: DieterRPC,
    connectionTask: Task<Void, Never>,
    rtcConfiguration: Dieter_Gateway_V1_RTCConfiguration,
    daemonCertificatePEM: Data,
    routeLabel: String
  ) {
    self.rpc = rpc
    self.connectionTask = connectionTask
    self.rtcConfiguration = rtcConfiguration
    self.daemonCertificatePEM = daemonCertificatePEM
    self.routeLabel = routeLabel
  }

  func shutdown() {
    connectionTask.cancel()
    rpc.shutdown()
  }
}
