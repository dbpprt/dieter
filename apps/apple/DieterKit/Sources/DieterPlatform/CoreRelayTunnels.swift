import DieterCore
import DieterTransport
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Synchronization

/// The core's relay tunnels: `RelayService.OpenTunnel` streams to the gateway,
/// each bridged to a loopback port that the daemon TLS client then dials.
/// Tunnels to one gateway share one HTTP/2 connection.
public final class CoreRelayTunnels: NSObject, NativeTunnels, Sendable {
    private typealias Client = GRPCClient<HTTP2ClientTransport.Posix>
    private let clients = Mutex<[String: Client]>([:])

    deinit {
        clients.withLock { $0.values.forEach { $0.beginGracefulShutdown() } }
    }

    public func open(
        url: String, sessionToken: String, clientVersion: String, daemonId: String, lane: Int32,
        completion: any NativeTunnelCompletion
    ) {
        let completion = NativeCallback(completion)
        Task {
            do {
                let tunnel = try await RelayTunnel.open(
                    client: try client(for: url), sessionToken: sessionToken, clientVersion: clientVersion,
                    daemonID: daemonId, lane: Int(lane))
                completion.value.completed(tunnel: CoreTunnel(tunnel), status: 0, error: nil)
            } catch let failure as RelayTunnelFailure {
                completion.value.completed(tunnel: nil, status: failure.status, error: failure.message)
            } catch {
                let (status, message) = CoreRpcBridge.status(of: error)
                completion.value.completed(tunnel: nil, status: status, error: message)
            }
        }
    }

    private func client(for url: String) throws -> Client {
        if let existing = clients.withLock({ $0[url] }) { return existing }
        let created = Client(transport: try CoreRpcBridge.gateway(url))
        let winner = clients.withLock { clients -> Client in
            if let existing = clients[url] { return existing }
            clients[url] = created
            return created
        }
        if winner === created {
            Task.detached { try? await created.runConnections() }
        } else {
            created.beginGracefulShutdown()
        }
        return winner
    }
}

private final class CoreTunnel: NSObject, NativeTunnel, Sendable {
    private let tunnel: RelayTunnel

    init(_ tunnel: RelayTunnel) {
        self.tunnel = tunnel
    }

    func port() -> Int32 { Int32(tunnel.port) }

    func close() { tunnel.close() }
}
