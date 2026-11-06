import DieterAPI
import DieterAPIGRPC
import DieterPlatform
import DieterTransport
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import SwiftProtobuf

/// A plain gRPC client to a disposable fixture daemon, for host-side checks
/// the app leaves to the shared core.
package final class FixtureRPCClient: Sendable {
    package typealias Transport = HTTP2ClientTransport.Posix
    private let client: GRPCClient<Transport>
    /// The daemon's remote desktop service, the only one these checks use.
    package let screens: Dieter_V1_ScreenService.Client<Transport>
    private let running: Task<Void, Never>

    /// Connects to `origin` (`http[s]://host:port`) with `token`.
    package init(origin: String, token: String?) throws {
        guard let url = URL(string: origin), let host = url.host(percentEncoded: false), let port = url.port
        else { throw RPCError(code: .invalidArgument, message: "Invalid fixture address \(origin)") }
        let transport = try HTTP2ClientTransport.Posix(
            target: DieterTransportTarget.make(host: host, port: port),
            transportSecurity: url.scheme == "https" ? .tls : .plaintext)
        client = GRPCClient(transport: transport, interceptors: [FixtureMetadata(token: token)])
        screens = Dieter_V1_ScreenService.Client(wrapping: client)
        running = Task { [client] in try? await client.runConnections() }
    }

    deinit { shutdown() }

    package func shutdown() {
        client.beginGracefulShutdown()
        running.cancel()
    }

    private static var bounded: CallOptions {
        var options = CallOptions.defaults
        options.timeout = .seconds(15)
        options.maxRequestMessageBytes = 16 * 1_024 * 1_024
        options.maxResponseMessageBytes = 16 * 1_024 * 1_024
        return options
    }

    package func remoteDesktopCapabilities() async throws -> Dieter_V1_RemoteDesktopCapabilities {
        try await screens.getRemoteDesktopCapabilities(
            request: .init(message: Google_Protobuf_Empty()), options: Self.bounded)
    }

    package func remoteDesktopSessions() async throws -> Dieter_V1_RemoteDesktopSessions {
        try await screens.listRemoteDesktopSessions(
            request: .init(message: Google_Protobuf_Empty()), options: Self.bounded)
    }

    package func remoteDesktopDisplayModes(sessionID: String) async throws -> Dieter_V1_RemoteDesktopDisplayModes {
        try await screens.listRemoteDesktopDisplayModes(
            request: .init(message: .with { $0.sessionID = sessionID }), options: Self.bounded)
    }

    /// Streams the session's signals to `receive` until the host closes it.
    package func startRemoteDesktop(
        _ request: Dieter_V1_StartRemoteDesktopRequest,
        receive: @Sendable @escaping (Dieter_V1_RemoteDesktopSignal) async throws -> Void
    ) async throws {
        try await screens.startRemoteDesktop(request: .init(message: request)) { response in
            for try await signal in response.messages {
                try Task.checkCancellation()
                try await receive(signal)
            }
        }
    }

    package func closeRemoteDesktop(sessionID: String) async throws {
        _ =
            try await screens.closeRemoteDesktop(
                request: .init(message: .with { $0.sessionID = sessionID }), options: Self.bounded)
            as Google_Protobuf_Empty
    }
}

/// The bearer token and client release every Dieter RPC carries.
private struct FixtureMetadata: ClientInterceptor {
    let token: String?

    func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingClientRequest<Input>, context: ClientContext,
        next: (StreamingClientRequest<Input>, ClientContext) async throws -> StreamingClientResponse<Output>
    ) async throws -> StreamingClientResponse<Output> {
        var request = request
        request.metadata.addString(DieterRelease.current, forKey: "x-dieter-client-version")
        if let token { request.metadata.addString("Bearer \(token)", forKey: "authorization") }
        return try await next(request, context)
    }
}
