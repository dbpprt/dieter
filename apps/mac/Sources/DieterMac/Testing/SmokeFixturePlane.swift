#if DIETER_UI_SMOKE
    import DieterClient
    import DieterCore
    import Foundation

    /// UI smoke fixtures prepare and inspect the isolated machine directly
    /// (start a process, create a card, read a file back): host-side work the
    /// app leaves to the shared core. One data plane to the attached machine,
    /// opened on demand and replaced when that machine changes. Smoke builds
    /// only; the app never uses it.
    @MainActor final class SmokeFixturePlane {
        static let shared = SmokeFixturePlane()
        private var connections: ConnectionManager?
        private var plane: (machineID: String, connection: DataPlaneConnection)?

        func rpc(for store: DieterStore) async -> DieterRPC? {
            guard store.phase.isConnected, store.endpoint.daemonID != nil else { return nil }
            let machine = store.endpoint
            if let plane, plane.machineID == machine.id { return plane.connection.rpc }
            plane?.connection.shutdown()
            plane = nil
            let connections =
                self.connections
                ?? ConnectionManager(factory: store.environment.clients, clock: store.environment.clock)
            self.connections = connections
            let origin =
                store.gatewayOrigins.first(where: { $0.credentialID == machine.credentialID })
                ?? machine.gatewayEndpoint
            let token = await store.accessToken(for: origin)
            do {
                let gateway = try store.environment.clients.client(endpoint: origin, accessToken: token)
                let gatewayTask = Task { try? await gateway.run() }
                defer {
                    gatewayTask.cancel()
                    gateway.shutdown()
                }
                let connection = try await connections.selectDataPlane(
                    gateway: gateway, target: machine, gatewayAccessToken: token, refreshDirectToken: true)
                guard store.endpoint.id == machine.id else {
                    connection.shutdown()
                    return nil
                }
                plane = (machine.id, connection)
                return connection.rpc
            } catch {
                return nil
            }
        }
    }

    extension DieterStore {
        /// See `SmokeFixturePlane`.
        func fixtureRPC() async -> DieterRPC? { await SmokeFixturePlane.shared.rpc(for: self) }
    }
#endif
