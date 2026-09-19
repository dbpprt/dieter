import DieterCore
import DieterAPI
import Foundation

extension ConnectionManager {
    package func controlConnection(
        gateway: DieterRPC, target: DieterEndpoint, gatewayAccessToken: String?,
        route: Dieter_Gateway_V1_DaemonRoute, refreshDirectToken: Bool,
        run: @escaping @MainActor (DieterRPC) -> Task<Void, Never>
    ) async throws -> DataPlaneConnection {
        let daemonID = route.daemonID
        let configuration = try await gateway.rtcConfiguration(daemonID: daemonID)
        let token = try await gateway.daemonAccessToken(daemonID: daemonID)
        guard token.tokenType == "Bearer" else { throw NSError(domain: "DieterControlRTC", code: 2) }
        let bridge = try ControlRTCBridge(configuration: configuration)
        var accepted = false
        defer { if !accepted { bridge.close() } }
        let bootstrap = try DieterRPC(
            endpoint: target, accessToken: gatewayAccessToken, route: .relay(daemonID: daemonID))
        let bootstrapTask = run(bootstrap)
        defer { bootstrapTask.cancel(); bootstrap.shutdown() }
        var request = Dieter_V1_StartControlConnectionRequest()
        request.rtcConfiguration = configuration
        request.offerSdp = try await bridge.offer()
        let session = try await bootstrap.service.startControlConnection(
            request: .init(message: request), options: DieterRPC.boundedUnaryCallOptions())
        let port = try await bridge.connect(answer: session.answerSdp)
        let rpc = try DieterRPC(
            endpoint: target,
            direct: .init(
                host: "127.0.0.1", port: port, daemonID: daemonID, daemonCAPEM: route.daemonCaPem,
                accessToken: token.accessToken, expiresAt: token.expiresAt, daemonGeneration: token.daemonGeneration),
            controlBridge: bridge)
        let task = run(rpc)
        do {
            let started = Date()
            _ = try await rpc.health(timeout: .seconds(5))
            var reference = Dieter_V1_ControlConnectionRef()
            reference.sessionID = session.sessionID
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
            return DataPlaneConnection(
                rpc: rpc, task: task,
                connection: .init(
                    route: mode, latencyMilliseconds: max(0, Int(Date().timeIntervalSince(started) * 1000))),
                directTokenExpiresAt: token.expiresAt, directCredential: rpc.directCredential,
                credentialRefreshTask: renewal)
        } catch {
            task.cancel(); rpc.shutdown(); throw error
        }
    }
}
