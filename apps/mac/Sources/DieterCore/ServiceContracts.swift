import DieterAPI
import Foundation

package protocol ScreenSignalingRPC: AnyObject, Sendable {
    func remoteDesktopCapabilities() async throws -> Dieter_V1_RemoteDesktopCapabilities
    func startRemoteDesktop(
        _ request: Dieter_V1_StartRemoteDesktopRequest,
        receive: @escaping @Sendable (Dieter_V1_RemoteDesktopSignal) async throws -> Void) async throws
    func sendRemoteDesktopSignal(_ signal: Dieter_V1_RemoteDesktopSignal) async throws
    func remoteDesktopSession(sessionID: String) async throws -> Dieter_V1_RemoteDesktopSessionState
    func updateRemoteDesktopSession(_ request: Dieter_V1_UpdateRemoteDesktopSessionRequest) async throws
        -> Dieter_V1_RemoteDesktopSessionState
    func setRemoteDesktopControl(sessionID: String, take: Bool) async throws -> Dieter_V1_RemoteDesktopSessionState
    func closeRemoteDesktop(sessionID: String) async throws
    func remoteDesktopDisplayModes(sessionID: String) async throws -> Dieter_V1_RemoteDesktopDisplayModes
    func setRemoteDesktopDisplayMode(_ request: Dieter_V1_SetRemoteDesktopDisplayModeRequest) async throws
        -> Dieter_V1_RemoteDesktopDisplayModes
    func restoreRemoteDesktopDisplayMode(sessionID: String) async throws -> Dieter_V1_RemoteDesktopDisplayModes
    func shutdown()
}

package protocol ProviderQuotaRPC: AnyObject, Sendable {
    func providerQuotas() async throws -> Dieter_Gateway_V1_ListProviderQuotasResponse
    func refreshProviderQuotas() async throws -> Dieter_Gateway_V1_RefreshProviderQuotasResponse
    func setProviderQuotaSummaryInclusion(
        provider: Dieter_Gateway_V1_ProviderQuotaProvider, accountKey: String, included: Bool
    ) async throws -> Dieter_Gateway_V1_SetProviderQuotaSummaryInclusionResponse
    func consumeProviderQuotaReset(accountKey: String, idempotencyKey: String) async throws
        -> Dieter_Gateway_V1_ConsumeProviderQuotaResetResponse
}
