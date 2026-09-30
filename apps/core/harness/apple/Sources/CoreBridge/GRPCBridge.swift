import DieterShared
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Synchronization

/// The Apple native extension behind the shared core's transport: grpc-swift
/// owns HTTP/2, gRPC trailers, and TLS. Routing, retries, and payload encoding
/// stay in Kotlin; this type only moves bytes for one method path. Each core
/// channel gets one HTTP/2 connection, released when the core retires it.
public final class GRPCBridge: NSObject, NativeRpcBridge, Sendable {
    private typealias Client = GRPCClient<HTTP2ClientTransport.Posix>
    private struct Channels {
        var open: [String: Client] = [:]
        var released: Set<String> = []
    }
    private let channels = Mutex(Channels())

    deinit {
        channels.withLock { $0.open.values.forEach { $0.beginGracefulShutdown() } }
    }

    public func unary(target: NativeRpcTarget, path: String, request: Data, completion: any NativeUnaryCompletion) -> any NativeRpcCancellable {
        let bytes = [UInt8](request), destination = Destination(target)
        let completion = KotlinCallback(completion)
        let task = Task {
            do {
                let response = try await client(for: destination).unary(
                    request: ClientRequest(message: bytes, metadata: destination.metadata),
                    descriptor: try descriptor(path), serializer: RawBytes(), deserializer: RawBytes(), options: .defaults
                ) { try $0.message }
                completion.value.succeeded(response: Data(response))
            } catch {
                let (status, message) = Self.status(of: error)
                completion.value.failed(status: status, message: message)
            }
        }
        return TaskCancellable(task)
    }

    public func serverStreaming(target: NativeRpcTarget, path: String, request: Data, observer: any NativeStreamObserver) -> any NativeRpcCancellable {
        let bytes = [UInt8](request), destination = Destination(target)
        let observer = KotlinCallback(observer)
        let task = Task {
            do {
                try await client(for: destination).serverStreaming(
                    request: ClientRequest(message: bytes, metadata: destination.metadata),
                    descriptor: try descriptor(path), serializer: RawBytes(), deserializer: RawBytes(), options: .defaults
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

    public func release(channelId: String) {
        let client = channels.withLock { channels -> Client? in
            channels.released.insert(channelId)
            return channels.open.removeValue(forKey: channelId)
        }
        client?.beginGracefulShutdown()
    }

    private func descriptor(_ path: String) throws -> MethodDescriptor {
        let parts = path.split(separator: "/")
        guard parts.count == 2 else { throw RPCError(code: .internalError, message: "invalid method path \(path)") }
        return MethodDescriptor(fullyQualifiedService: String(parts[0]), method: String(parts[1]))
    }

    private func client(for target: Destination) throws -> Client {
        if let existing = channels.withLock({ $0.open[target.channel] }) { return existing }
        guard target.kind != NativeRpcTarget.companion.DIRECT else {
            // The apps reuse DieterRPC's SPIFFE-pinned TLS (verifyDaemonCertificateChain)
            // for direct targets; the harness declines them and the core uses the relay.
            throw RPCError(code: .unavailable, message: "direct TLS is not wired into this harness")
        }
        guard let url = URL(string: target.url), let host = url.host else {
            throw RPCError(code: .invalidArgument, message: "invalid gateway URL \(target.url)")
        }
        let secure = url.scheme == "https"
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: host, port: url.port ?? (secure ? 443 : 80)),
            transportSecurity: secure ? .tls : .plaintext
        )
        let created = Client(transport: transport)
        let winner = try channels.withLock { channels -> Client in
            guard !channels.released.contains(target.channel) else {
                throw RPCError(code: .unavailable, message: "the channel was released")
            }
            if let existing = channels.open[target.channel] { return existing }
            channels.open[target.channel] = created
            return created
        }
        if winner === created { Task.detached { try? await created.runConnections() } }
        return winner
    }

    private static func status(of error: any Error) -> (Int32, String) {
        switch error {
        case let error as RPCError: (Int32(error.code.rawValue), error.message)
        case is CancellationError: (1, "cancelled")
        default: (14, String(describing: error))
        }
    }
}

/// A Sendable copy of the Kotlin NativeRpcTarget for use inside tasks.
private struct Destination: Sendable {
    let kind: String, channel: String, url: String, metadata: Metadata

    init(_ target: NativeRpcTarget) {
        kind = target.kind
        channel = target.channelId
        url = target.url
        var metadata = Metadata()
        metadata.addString(target.authorization, forKey: "authorization")
        metadata.addString(target.clientVersion, forKey: "x-dieter-client-version")
        if target.kind == NativeRpcTarget.companion.RELAY { metadata.addString(target.daemonId, forKey: "x-dieter-daemon-id") }
        self.metadata = metadata
    }
}

/// Kotlin/Native objects may be called from any thread, but Swift cannot see
/// that; this box states it where callbacks cross into grpc-swift tasks.
struct KotlinCallback<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
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
