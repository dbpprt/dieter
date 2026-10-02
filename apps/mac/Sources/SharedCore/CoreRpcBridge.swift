import DieterShared
import DieterTransport
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Synchronization

/// The native transport behind the shared core: grpc-swift owns HTTP/2, gRPC
/// trailers, and TLS. Route choice, retries, and payload encoding stay in the
/// core; this type only moves bytes for one method path. Each core channel
/// gets one HTTP/2 connection, released when the core retires it.
///
/// Direct targets pin the daemon: the chain must end at the enrolled daemon CA
/// and the leaf must carry the exact SPIFFE URI SAN. Host names are not trusted.
package final class CoreRpcBridge: NSObject, NativeRpcBridge, Sendable {
    private typealias Client = GRPCClient<HTTP2ClientTransport.Posix>
    private struct Channels {
        var open: [String: Client] = [:]
        // Channels the core retired before their connection was created; kept
        // bounded, oldest first, since channel IDs never repeat.
        var released: [String] = []
        var releasedSet: Set<String> = []
    }

    /// Attachments and transcript pages can exceed grpc-swift's 4 MiB default.
    static let maximumMessageBytes = 32 * 1_024 * 1_024
    private static let releasedLimit = 1_024
    private let channels = Mutex(Channels())

    deinit {
        channels.withLock { $0.open.values.forEach { $0.beginGracefulShutdown() } }
    }

    package func unary(
        target: NativeRpcTarget, path: String, request: Data, completion: any NativeUnaryCompletion
    ) -> any NativeRpcCancellable {
        let bytes = [UInt8](request)
        let destination = Destination(target)
        let completion = NativeCallback(completion)
        let task = Task {
            do {
                let response = try await client(for: destination).unary(
                    request: ClientRequest(message: bytes, metadata: destination.metadata),
                    descriptor: try Self.descriptor(path), serializer: RawBytes(), deserializer: RawBytes(),
                    options: Self.callOptions
                ) { try $0.message }
                completion.value.succeeded(response: Data(response))
            } catch {
                let (status, message) = Self.status(of: error)
                completion.value.failed(status: status, message: message)
            }
        }
        return TaskCancellable(task)
    }

    package func serverStreaming(
        target: NativeRpcTarget, path: String, request: Data, observer: any NativeStreamObserver
    ) -> any NativeRpcCancellable {
        let bytes = [UInt8](request)
        let destination = Destination(target)
        let observer = NativeCallback(observer)
        let task = Task {
            do {
                try await client(for: destination).serverStreaming(
                    request: ClientRequest(message: bytes, metadata: destination.metadata),
                    descriptor: try Self.descriptor(path), serializer: RawBytes(), deserializer: RawBytes(),
                    options: Self.callOptions
                ) { response in
                    for try await message in response.messages { observer.value.message(payload: Data(message)) }
                }
                observer.value.closed(status: 0, message: "")
            } catch {
                let (status, message) = Self.status(of: error)
                observer.value.closed(status: status, message: message)
            }
        }
        return TaskCancellable(task)
    }

    package func release(channelId: String) {
        let client = channels.withLock { channels -> Client? in
            if channels.releasedSet.insert(channelId).inserted {
                channels.released.append(channelId)
                if channels.released.count > Self.releasedLimit {
                    channels.releasedSet.remove(channels.released.removeFirst())
                }
            }
            return channels.open.removeValue(forKey: channelId)
        }
        client?.beginGracefulShutdown()
    }

    private static var callOptions: CallOptions {
        var options = CallOptions.defaults
        options.maxRequestMessageBytes = maximumMessageBytes
        options.maxResponseMessageBytes = maximumMessageBytes
        return options
    }

    private static func descriptor(_ path: String) throws -> MethodDescriptor {
        let parts = path.split(separator: "/")
        guard parts.count == 2 else { throw RPCError(code: .internalError, message: "invalid method path \(path)") }
        return MethodDescriptor(fullyQualifiedService: String(parts[0]), method: String(parts[1]))
    }

    private func client(for target: Destination) throws -> Client {
        if let existing = channels.withLock({ $0.open[target.channel] }) { return existing }
        let transport = try Self.transport(for: target)
        let created = Client(transport: transport)
        let winner = try channels.withLock { channels -> Client in
            guard !channels.releasedSet.contains(target.channel) else {
                throw RPCError(code: .unavailable, message: "the channel was released")
            }
            if let existing = channels.open[target.channel] { return existing }
            channels.open[target.channel] = created
            return created
        }
        if winner === created {
            Task.detached { try? await created.runConnections() }
        } else {
            created.beginGracefulShutdown()
        }
        return winner
    }

    private static func transport(for target: Destination) throws -> HTTP2ClientTransport.Posix {
        if target.kind == NativeRpcTarget.companion.DIRECT {
            let daemonCAPEM = Data(target.daemonCaPem.utf8)
            let daemonID = target.daemonId
            let security: HTTP2ClientTransport.Posix.TransportSecurity = .tls { config in
                config.trustRoots = .certificates([.bytes(Array(daemonCAPEM), format: .pem)])
                // Direct candidates are IP targets; the daemon's identity is its
                // SPIFFE URI SAN, verified below together with the CA chain.
                config.serverCertificateVerification = .noHostnameVerification
                config.verifySignatureAlgorithms = [.ed25519]
                config.customVerificationCallback = { certificates, promise in
                    let chain = certificates.compactMap { try? Data($0.toDERBytes()) }
                    let verified = DaemonCertificatePinning.verify(
                        chain, daemonCAPEM: daemonCAPEM, daemonID: daemonID)
                    promise.succeed(verified ? .certificateVerified(.init(nil)) : .failed)
                }
            }
            return try .http2NIOPosix(
                target: DieterTransportTarget.make(host: target.host, port: Int(target.port)),
                transportSecurity: security)
        }
        guard let url = URL(string: target.url), let host = url.host else {
            throw RPCError(code: .invalidArgument, message: "invalid gateway URL \(target.url)")
        }
        let secure = url.scheme == "https"
        return try .http2NIOPosix(
            target: DieterTransportTarget.make(host: host, port: url.port ?? (secure ? 443 : 80)),
            transportSecurity: secure ? .tls : .plaintext)
    }

    /// The gRPC status the core classifies. Transport-level grpc-swift errors
    /// and dropped connections are UNAVAILABLE (retryable); an empty unary
    /// response, which grpc-swift reports as UNIMPLEMENTED, is also a dropped
    /// connection rather than a missing method.
    static func status(of error: any Error) -> (Int32, String) {
        switch error {
        case let error as RPCError:
            if error.code == .unimplemented, error.message == "No messages received, exactly one was expected." {
                return (14, error.message)
            }
            return (Int32(error.code.rawValue), error.message)
        case is CancellationError:
            return (1, "cancelled")
        case let error as RuntimeError:
            return (14, error.message)
        default:
            return (14, (error as NSError).localizedDescription)
        }
    }
}

/// A Sendable copy of the core's NativeRpcTarget for use inside tasks.
private struct Destination: Sendable {
    let kind: String
    let channel: String
    let url: String
    let host: String
    let port: Int32
    let daemonId: String
    let daemonCaPem: String
    let metadata: Metadata

    init(_ target: NativeRpcTarget) {
        kind = target.kind
        channel = target.channelId
        url = target.url
        host = target.host
        port = target.port
        daemonId = target.daemonId
        daemonCaPem = target.daemonCaPem
        var metadata = Metadata()
        metadata.addString(target.authorization, forKey: "authorization")
        metadata.addString(target.clientVersion, forKey: "x-dieter-client-version")
        if target.kind == NativeRpcTarget.companion.RELAY { metadata.addString(target.daemonId, forKey: "x-dieter-daemon-id") }
        self.metadata = metadata
    }
}

/// Kotlin/Native callbacks may be called from any thread, but Swift cannot see
/// that; this box states it where a callback crosses into a task.
package struct NativeCallback<Value>: @unchecked Sendable {
    package let value: Value
    package init(_ value: Value) { self.value = value }
}

private struct RawBytes: MessageSerializer, MessageDeserializer {
    func serialize<Bytes: GRPCContiguousBytes>(_ message: [UInt8]) throws -> Bytes { Bytes(message) }
    func deserialize<Bytes: GRPCContiguousBytes>(_ serializedMessageBytes: Bytes) throws -> [UInt8] {
        serializedMessageBytes.withUnsafeBytes { Array($0) }
    }
}

private final class TaskCancellable: NSObject, NativeRpcCancellable, Sendable {
    private let task: Task<Void, Never>
    init(_ task: Task<Void, Never>) { self.task = task }
    func cancel() { task.cancel() }
}
