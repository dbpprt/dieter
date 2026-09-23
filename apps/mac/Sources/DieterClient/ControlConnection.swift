import DieterCore
import DieterAPI
import Foundation
import OSLog

private let controlConnectionLogger = Logger(
    subsystem: "com.dbpprt.dieter.mac", category: "ControlWebRTC")

package struct ControlRouteDiagnosticError: LocalizedError {
    package let stage: String
    package let reason: String
    package let elapsedMilliseconds: Int
    let underlying: Error

    package var errorDescription: String? {
        "WebRTC control route failed during \(stage) (\(reason))."
    }
}

private func sanitizedControlReason(_ error: Error) -> String {
    if error is CancellationError { return "canceled" }
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain { return "network" }
    let text = ns.localizedDescription.lowercased()
    if text.contains("timed out") || text.contains("timeout") { return "deadline" }
    if text.contains("certificate") || text.contains("tls") { return "tls" }
    return "unavailable"
}

extension ConnectionManager {
    package func controlConnection(
        gateway: DieterRPC, target: DieterEndpoint, gatewayAccessToken: String?,
        route: Dieter_Gateway_V1_DaemonRoute, refreshDirectToken: Bool,
        run: @escaping @MainActor (DieterRPC) -> Task<Void, Never>
    ) async throws -> DataPlaneConnection {
        let routeStarted = Date()
        var stage = "configuration"
        do {
            let daemonID = route.daemonID
            let configuration = try await gateway.rtcConfiguration(daemonID: daemonID)
            let token = try await gateway.daemonAccessToken(daemonID: daemonID)
            guard token.tokenType == "Bearer" else { throw NSError(domain: "DieterControlRTC", code: 2) }
            let bridge = try ControlRTCBridge(configuration: configuration)
            var accepted = false
            defer { if !accepted { bridge.close() } }
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let bootstrap = try DieterRPC(
                    endpoint: target, accessToken: gatewayAccessToken, route: .relay(daemonID: daemonID))
                let bootstrapTask = run(bootstrap)
                defer { bootstrapTask.cancel(); bootstrap.shutdown() }
                var request = Dieter_V1_StartControlConnectionRequest()
                request.rtcConfiguration = configuration
                stage = "ice-gathering"
                request.offerSdp = try await bridge.offer()
                let candidateSummary = ControlRTCBridge.candidateSummary(in: request.offerSdp)
                controlConnectionLogger.debug(
                    "WebRTC offer gathered host=\(candidateSummary.host) srflx=\(candidateSummary.srflx) relay=\(candidateSummary.relay)"
                )
                stage = "signaling"
                let session = try await bootstrap.service.startControlConnection(
                    request: .init(message: request), options: DieterRPC.boundedUnaryCallOptions())
                stage = "data-channel"
                let port = try await bridge.connect(answer: session.answerSdp)
                stage = "tls"
                let rpc = try DieterRPC(
                    endpoint: target,
                    direct: .init(
                        host: "127.0.0.1", port: port, daemonID: daemonID, daemonCAPEM: route.daemonCaPem,
                        accessToken: token.accessToken, expiresAt: token.expiresAt,
                        daemonGeneration: token.daemonGeneration),
                    controlBridge: bridge)
                let task = run(rpc)
                do {
                    let started = Date()
                    stage = "health"
                    _ = try await rpc.health(timeout: .seconds(5))
                    var reference = Dieter_V1_ControlConnectionRef()
                    reference.sessionID = session.sessionID
                    stage = "status"
                    let status = try await rpc.service.getControlConnection(
                        request: .init(message: reference), options: DieterRPC.boundedUnaryCallOptions())
                    try Task.checkCancellation()
                    let mode: MachineConnectionRoute =
                        status.mode == "turn" ? .webrtcTURN : status.mode == "direct" ? .webrtcDirect : .webrtc
                    // The gateway object may belong to a short-lived caller. Renew via
                    // independently owned gateway connections, just like direct TLS.
                    var renewal: Task<Void, Never>?
                    if refreshDirectToken, let credential = rpc.directCredential {
                        let endpoint = gateway.endpoint
                        renewal = Task {
                            await DirectCredentialRefreshLoop.run(credential: credential) {
                                let issuer = try DieterRPC(endpoint: endpoint, accessToken: gatewayAccessToken)
                                let issuerTask = Task { try? await issuer.run() }
                                defer { issuerTask.cancel(); issuer.shutdown() }
                                return try await issuer.daemonAccessToken(daemonID: daemonID)
                            }
                        }
                    }
                    accepted = true
                    controlConnectionLogger.info(
                        "WebRTC control route healthy for \(daemonID, privacy: .public); mode=\(mode.rawValue, privacy: .public) elapsed_ms=\(max(0, Int(Date().timeIntervalSince(routeStarted) * 1000)))"
                    )
                    return DataPlaneConnection(
                        rpc: rpc, task: task,
                        connection: .init(
                            route: mode,
                            latencyMilliseconds: max(0, Int(Date().timeIntervalSince(started) * 1000))),
                        directTokenExpiresAt: token.expiresAt, directCredential: rpc.directCredential,
                        credentialRefreshTask: renewal)
                } catch {
                    task.cancel()
                    rpc.shutdown()
                    throw error
                }
            } onCancel: {
                bridge.close()
            }
        } catch let diagnostic as ControlRouteDiagnosticError {
            throw diagnostic
        } catch {
            throw ControlRouteDiagnosticError(
                stage: stage,
                reason: sanitizedControlReason(error),
                elapsedMilliseconds: max(0, Int(Date().timeIntervalSince(routeStarted) * 1_000)),
                underlying: error)
        }
    }
}
