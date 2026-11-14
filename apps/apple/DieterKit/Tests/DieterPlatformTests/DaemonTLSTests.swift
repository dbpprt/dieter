import CryptoKit
import DieterCore
import DieterTransport
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import NIOSSL
import Synchronization
import Testing

@testable import DieterPlatform

/// A daemon's DirectServer in miniature: TLS with an Ed25519 identity, a
/// required client certificate, and one raw echo method.
private final class TestDaemon: Sendable {
    static let path = "dieter.test.Echo/Call"
    let identity: TestCertificates.Daemon
    let seen = Seen()
    private let transport: HTTP2ServerTransport.Posix
    private let server: GRPCServer<HTTP2ServerTransport.Posix>
    private let serving: Task<Void, Never>

    /// What the daemon saw of its clients.
    final class Seen: Sendable {
        /// The SubjectPublicKeyInfo of every client certificate presented.
        let clientKeys = Mutex<[Data]>([])
        let authorizations = Mutex<[String]>([])
    }

    init() throws {
        let identity = try TestCertificates.daemon()
        self.identity = identity
        let seen = seen
        transport = HTTP2ServerTransport.Posix(
            address: .ipv4(host: "127.0.0.1", port: 0),
            transportSecurity: .mTLS(
                certificateChain: [.bytes(Array(identity.certificate), format: .der)],
                privateKey: .bytes(Array(identity.privateKeyDER), format: .der)
            ) { config in
                // Like the daemon: any client certificate; the roster decides.
                config.customVerificationCallback = { certificates, promise in
                    if let key = try? certificates.first?.extractPublicKey().toSPKIBytes() {
                        seen.clientKeys.withLock { $0.append(Data(key)) }
                    }
                    promise.succeed(.certificateVerified(.init(nil)))
                }
            })
        server = GRPCServer(transport: transport, services: [Echo(seen: seen)])
        let server = server
        serving = Task { try? await server.serve() }
    }

    var port: Int {
        get async throws { try #require(try await transport.listeningAddress.ipv4?.port) }
    }

    func stop() {
        server.beginGracefulShutdown()
        serving.cancel()
    }

    private struct Echo: RegistrableRPCService {
        let seen: Seen

        func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
            let seen = seen
            router.registerHandler(
                forMethod: MethodDescriptor(fullyQualifiedService: "dieter.test.Echo", method: "Call"),
                deserializer: RawBytes(), serializer: RawBytes()
            ) { request, _ in
                let values = request.metadata[stringValues: "authorization"].map { String($0) }
                seen.authorizations.withLock { $0 += values }
                var body: [UInt8] = []
                for try await message in request.messages { body += message }
                return StreamingServerResponse(single: ServerResponse(message: Array("echo:".utf8) + body))
            }
        }
    }
}

private final class UnaryResult: NSObject, NativeUnaryCompletion, Sendable {
    private let continuation: CheckedContinuation<Result<Data, UnaryFailure>, Never>

    init(_ continuation: CheckedContinuation<Result<Data, UnaryFailure>, Never>) {
        self.continuation = continuation
    }

    func succeeded(response: Data) { continuation.resume(returning: .success(response)) }

    func failed(status: Int32, message: String) {
        continuation.resume(returning: .failure(UnaryFailure(status: status, message: message)))
    }
}

private struct UnaryFailure: Error {
    let status: Int32
    let message: String
}

private func call(
    _ bridge: CoreRpcBridge, channel: String, port: Int, daemonPublicKey: Data, clientCertificate: Data
) async -> Result<Data, UnaryFailure> {
    let target = NativeRpcTarget(
        kind: NativeRpcTarget.companion.DIRECT, channelId: channel, url: "https://127.0.0.1:\(port)",
        authorization: "Bearer daemon-token", clientVersion: "0.5.0-test", daemonId: "d_test",
        host: "127.0.0.1", port: Int32(port), daemonPublicKey: daemonPublicKey,
        clientCertificate: clientCertificate)
    return await withCheckedContinuation { continuation in
        _ = bridge.unary(
            target: target, path: TestDaemon.path, request: Data("ping".utf8),
            completion: UnaryResult(continuation))
    }
}

@Test func directRoutesRunMutualTLSPinnedToTheRosterKeyWithTheDeviceKey() async throws {
    let daemon = try TestDaemon()
    defer { daemon.stop() }
    let port = try await daemon.port
    let directory = FileManager.default.temporaryDirectory.appending(path: "dieter-direct-tls-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    // The Secure Enclave key where this Mac has one, as the app uses it.
    let keys = CoreDeviceKeys(
        store: DeviceKeyFile(url: directory.appending(path: "device-key.json")), platform: "macos",
        deviceName: "Test Mac")
    let devicePublicKey = keys.publicKey()
    let certificate = try TestCertificates.device(devicePublicKey)
    let bridge = CoreRpcBridge(deviceKeys: keys)
    defer {
        bridge.release(channelId: "pinned")
        bridge.release(channelId: "other-key")
    }

    let answer = await call(
        bridge, channel: "pinned", port: port, daemonPublicKey: daemon.identity.publicKey,
        clientCertificate: certificate)
    #expect(try answer.get() == Data("echo:ping".utf8))
    // The daemon saw this device's key and the daemon token.
    #expect(daemon.seen.clientKeys.withLock { $0 } == [devicePublicKey])
    #expect(daemon.seen.authorizations.withLock { $0 } == ["Bearer daemon-token"])

    // Any other key is refused before a request leaves the device.
    let impostor = try TestCertificates.daemon()
    let refused = await call(
        bridge, channel: "other-key", port: port, daemonPublicKey: impostor.publicKey,
        clientCertificate: certificate)
    guard case .failure(let failure) = refused else {
        Issue.record("a daemon with another key was accepted")
        return
    }
    #expect(failure.status == 14)
    #expect(daemon.seen.authorizations.withLock { $0 }.count == 1)
}
