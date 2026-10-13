import DieterAPI
import DieterAPIGRPC
import DieterTransport
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import Synchronization
import Testing

private typealias Frame = Dieter_Gateway_V1_TunnelFrame

/// A gateway's `RelayService.OpenTunnel` in miniature: it answers OPEN with
/// `answer`, records what the client sends, and sends what the test queues.
private final class FakeRelay: Sendable {
    let answer: Frame
    let received = Mutex<[Frame]>([])
    let metadata = Mutex<[String: String]>([:])
    let ended = Mutex(false)
    private let outgoing: AsyncStream<Frame>
    private let sender: AsyncStream<Frame>.Continuation
    private let transport: HTTP2ServerTransport.Posix
    private let server: GRPCServer<HTTP2ServerTransport.Posix>
    private let serving: Task<Void, Never>

    init(answer: Frame) {
        self.answer = answer
        (outgoing, sender) = AsyncStream.makeStream(of: Frame.self)
        transport = HTTP2ServerTransport.Posix(
            address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext)
        let service = Service(relay: nil)
        server = GRPCServer(transport: transport, services: [service])
        let server = server
        serving = Task { try? await server.serve() }
        service.relay.withLock { $0 = self }
    }

    var client: GRPCClient<HTTP2ClientTransport.Posix> {
        get async throws {
            let port = try #require(try await transport.listeningAddress.ipv4?.port)
            return GRPCClient(
                transport: try .http2NIOPosix(
                    target: .ipv4(address: "127.0.0.1", port: port), transportSecurity: .plaintext))
        }
    }

    func send(_ frame: Frame) { sender.yield(frame) }

    func frames(_ kind: Dieter_Gateway_V1_TunnelFrameKind) -> [Frame] {
        received.withLock { $0.filter { $0.kind == kind } }
    }

    var dataBytes: Int { frames(.data).reduce(0) { $0 + $1.data.count } }

    func stop() {
        sender.finish()
        server.beginGracefulShutdown()
        serving.cancel()
    }

    fileprivate func serve(_ request: StreamingServerRequest<Frame>) -> StreamingServerResponse<Frame> {
        var values: [String: String] = [:]
        for key in ["authorization", "x-dieter-client-version"] {
            for value in request.metadata[stringValues: key] { values[key] = String(value) }
        }
        metadata.withLock { $0 = values }
        return StreamingServerResponse { writer in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await frame in request.messages {
                        self.received.withLock { $0.append(frame) }
                        if frame.kind == .open { self.sender.yield(self.answer) }
                        if frame.kind == .close { break }
                    }
                    self.ended.withLock { $0 = true }
                }
                group.addTask {
                    for await frame in self.outgoing {
                        try await writer.write(frame)
                        if frame.kind == .close { return }
                    }
                }
                try await group.next()
                group.cancelAll()
            }
            return [:]
        }
    }

    private final class Service: RegistrableRPCService {
        let relay: Mutex<FakeRelay?>

        init(relay: FakeRelay?) { self.relay = Mutex(relay) }

        func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
            router.registerHandler(
                forMethod: Dieter_Gateway_V1_RelayService.Method.OpenTunnel.descriptor,
                deserializer: ProtobufDeserializer<Frame>(), serializer: ProtobufSerializer<Frame>()
            ) { [self] request, _ in
                try #require(relay.withLock { $0 }).serve(request)
            }
        }
    }
}

/// Opens a tunnel to the fake gateway with a running client.
private func withTunnel(
    _ relay: FakeRelay, _ body: (RelayTunnel, LoopbackSocket) async throws -> Void
) async throws {
    let client = try await relay.client
    let running = Task { try? await client.runConnections() }
    defer {
        client.beginGracefulShutdown()
        running.cancel()
    }
    let tunnel = try await RelayTunnel.open(
        client: client, sessionToken: "session-token", clientVersion: "0.5.0-test", daemonID: "d_test",
        lane: Dieter_Gateway_V1_RelayLane.command.rawValue)
    defer { tunnel.close() }
    let socket = LoopbackSocket(port: tunnel.port)
    defer { socket.close() }
    try await socket.connect()
    try await body(tunnel, socket)
}

private let opened = Frame.with { $0.kind = .opened }

@Test func relayTunnelsOpenWithTheSessionAndKeepEightFramesInFlight() async throws {
    let relay = FakeRelay(answer: opened)
    defer { relay.stop() }
    try await withTunnel(relay) { tunnel, socket in
        let open = try #require(relay.frames(.open).first)
        #expect(open.daemonID == "d_test" && open.lane == .command)
        #expect(
            relay.metadata.withLock { $0 } == [
                "authorization": "Bearer session-token", "x-dieter-client-version": "0.5.0-test",
            ])
        let port = tunnel.port
        #expect(port > 0)

        // Without credit, the tunnel sends at most eight DATA frames.
        let payload = Data((0..<(2 * 1_024 * 1_024)).map { UInt8(truncatingIfNeeded: $0) })
        let writing = Task { try await socket.send(payload) }
        #expect(await eventually { relay.frames(.data).count == RelayTunnel.window })
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(relay.frames(.data).count == RelayTunnel.window)
        #expect(relay.frames(.data).allSatisfy { $0.data.count <= RelayTunnel.maximumData })

        // Credit releases the rest, in order and complete, never more than
        // eight frames ahead of it.
        var credited = 0
        while relay.dataBytes < payload.count {
            let sent = relay.frames(.data).count
            if sent > credited {
                relay.send(
                    .with {
                        $0.kind = .window
                        $0.credit = UInt32(sent - credited)
                    })
                credited = sent
            }
            #expect(await eventually { relay.frames(.data).count > sent || relay.dataBytes >= payload.count })
            #expect(relay.frames(.data).count - credited <= RelayTunnel.window)
        }
        try await writing.value
        #expect(Data(relay.frames(.data).flatMap(\.data)) == payload)
        let sent = relay.frames(.data).count
        if sent > credited {
            relay.send(
                .with {
                    $0.kind = .window
                    $0.credit = UInt32(sent - credited)
                })
        }

        // Gateway DATA reaches the socket and is credited once written.
        relay.send(
            .with {
                $0.kind = .data
                $0.data = Data("hello from the daemon".utf8)
            })
        var echoed = Data()
        while echoed.count < 21 { echoed += try #require(try await socket.receive()) }
        #expect(echoed == Data("hello from the daemon".utf8))
        #expect(await eventually { relay.frames(.window).contains { $0.credit == 1 } })

        // The socket's end closes the tunnel and ends the stream.
        socket.close()
        #expect(await eventually { relay.frames(.close).count == 1 && relay.ended.withLock { $0 } })
        let closed = tunnel.isClosed
        #expect(closed)
    }
}

@Test func relayTunnelsFailWithTheGatewaysCloseStatus() async throws {
    let relay = FakeRelay(
        answer: .with {
            $0.kind = .close
            $0.statusCode = 5
            $0.statusMessage = "This machine is not connected."
        })
    defer { relay.stop() }
    do {
        try await withTunnel(relay) { _, _ in Issue.record("the tunnel opened") }
    } catch let failure as RelayTunnelFailure {
        #expect(failure.status == 5)
        #expect(failure.message == "This machine is not connected.")
    }
}

@Test func relayTunnelsCloseOnCreditForFramesNeverSentAndOnGatewayClose() async throws {
    let relay = FakeRelay(answer: opened)
    defer { relay.stop() }
    try await withTunnel(relay) { tunnel, socket in
        relay.send(
            .with {
                $0.kind = .window
                $0.credit = 1
            })
        #expect(await eventually { tunnel.isClosed })
        let end = try await socket.receive()
        #expect(end == nil, "the socket closed with the tunnel")
        #expect(await eventually { relay.frames(.close).count == 1 })
    }

    let closing = FakeRelay(answer: opened)
    defer { closing.stop() }
    try await withTunnel(closing) { tunnel, socket in
        closing.send(.with { $0.kind = .close })
        #expect(await eventually { tunnel.isClosed })
        let end = try await socket.receive()
        #expect(end == nil)
        // A tunnel the gateway closed does not answer with another CLOSE.
        #expect(closing.frames(.close).isEmpty)
    }
}
