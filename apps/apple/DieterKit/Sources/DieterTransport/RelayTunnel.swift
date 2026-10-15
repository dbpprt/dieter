import DieterAPI
import DieterAPIGRPC
import Foundation
import GRPCCore
import Network
import Synchronization

/// One relay tunnel (`dieter.gateway.v1.RelayService/OpenTunnel`) bridged to
/// a loopback port that accepts exactly one connection; the daemon TLS client
/// connects there. The gateway only ever sees the TLS bytes.
///
/// Bytes read from the socket leave as DATA frames of at most `maximumData`
/// bytes while fewer than `window` are uncredited; each received DATA frame is
/// written to the socket and then credited with WINDOW{credit: 1}. CLOSE, the
/// end of the stream, the socket's end, or `close()` ends both directions once.
public final class RelayTunnel: @unchecked Sendable {
    /// DATA frames each side may have uncredited.
    public static let window = 8
    /// The largest DATA payload.
    public static let maximumData = 64 * 1_024

    private typealias Frame = Dieter_Gateway_V1_TunnelFrame

    private let queue = DispatchQueue(label: "dieter.relay-tunnel")
    private let send: @Sendable (Dieter_Gateway_V1_TunnelFrame) -> Void
    private let finish: @Sendable () -> Void
    private let acceptTimeout: TimeInterval
    // Confined to `queue`.
    private var listener: NWListener?
    private var socket: NWConnection?
    private var listening: CheckedContinuation<Int, any Error>?
    private var accepted = false
    private var connected = false
    private var closed = false
    private var reading = false
    private var writing = false
    /// DATA frames sent and not yet credited.
    private var uncredited = 0
    /// Received DATA not yet written to the socket.
    private var incoming: [Data] = []
    private let boundPort = Mutex(0)

    /// `send` hands a frame to the stream; `finish` ends the stream's sending
    /// side once the tunnel closed. Neither may block.
    public init(
        send: @escaping @Sendable (Dieter_Gateway_V1_TunnelFrame) -> Void,
        finish: @escaping @Sendable () -> Void, acceptTimeout: TimeInterval = 30
    ) {
        self.send = send
        self.finish = finish
        self.acceptTimeout = acceptTimeout
    }

    /// The loopback port (127.0.0.1), once `listen()` returned.
    public var port: Int { boundPort.withLock { $0 } }

    public var isClosed: Bool { queue.sync { closed } }

    /// Opens the loopback listener and returns its port.
    public func listen() async throws -> Int {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, any Error>) in
            queue.async { self.start(listener, continuation) }
        }
        boundPort.withLock { $0 = port }
        return port
    }

    /// A frame the gateway sent after OPENED.
    public func receive(_ frame: Dieter_Gateway_V1_TunnelFrame) {
        queue.async { self.handle(frame) }
    }

    /// The gRPC stream ended; nothing more arrives.
    public func streamEnded() {
        queue.async { self.closeOnQueue(notify: false) }
    }

    /// Ends the tunnel; safe to call more than once.
    public func close() {
        queue.async { self.closeOnQueue(notify: true) }
    }

    private func start(_ listener: NWListener, _ continuation: CheckedContinuation<Int, any Error>) {
        guard !closed else { return continuation.resume(throwing: Self.failure("The relay tunnel closed.")) }
        self.listener = listener
        listening = continuation
        listener.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                guard let continuation = listening else { return }
                listening = nil
                if let port = listener.port {
                    continuation.resume(returning: Int(port.rawValue))
                    queue.asyncAfter(deadline: .now() + acceptTimeout) { [self] in
                        if !accepted { closeOnQueue(notify: true) }
                    }
                } else {
                    continuation.resume(throwing: Self.failure("The relay tunnel has no loopback port."))
                    closeOnQueue(notify: true)
                }
            case .failed(let error):
                listening?.resume(throwing: error)
                listening = nil
                closeOnQueue(notify: true)
            case .cancelled:
                listening?.resume(throwing: Self.failure("The relay tunnel closed."))
                listening = nil
            default: break
            }
        }
        listener.newConnectionHandler = { [self] connection in
            guard !accepted, !closed else { return connection.cancel() }
            accepted = true
            socket = connection
            listener.cancel()
            self.listener = nil
            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    connected = true
                    readSocket()
                    writeSocket()
                case .failed, .cancelled: closeOnQueue(notify: true)
                default: break
                }
            }
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
    }

    private func handle(_ frame: Dieter_Gateway_V1_TunnelFrame) {
        guard !closed else { return }
        switch frame.kind {
        case .data:
            // A peer within its window never has more than `window` frames waiting here.
            guard frame.data.count <= Self.maximumData, incoming.count + (writing ? 1 : 0) < Self.window else {
                return closeOnQueue(notify: true)
            }
            incoming.append(frame.data)
            writeSocket()
        case .window:
            // Credit for frames never sent is a protocol violation.
            let credit = Int(frame.credit)
            guard credit > 0, credit <= uncredited else { return closeOnQueue(notify: true) }
            uncredited -= credit
            readSocket()
        case .close:
            closeOnQueue(notify: false)
        default:
            closeOnQueue(notify: true)
        }
    }

    /// Socket to gateway, within the credit window.
    private func readSocket() {
        guard !closed, connected, !reading, uncredited < Self.window, let socket else { return }
        reading = true
        socket.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumData) {
            [self] data, _, complete, error in
            reading = false
            guard !closed else { return }
            if let data, !data.isEmpty {
                uncredited += 1
                send(
                    .with {
                        $0.kind = .data
                        $0.data = data
                    })
            }
            if complete || error != nil { return closeOnQueue(notify: true) }
            readSocket()
        }
    }

    /// Gateway to socket; each DATA frame is credited once written.
    private func writeSocket() {
        guard !closed, connected, !writing, !incoming.isEmpty, let socket else { return }
        writing = true
        let data = incoming.removeFirst()
        socket.send(
            content: data,
            completion: .contentProcessed { [self] error in
                writing = false
                guard !closed else { return }
                guard error == nil else { return closeOnQueue(notify: true) }
                send(
                    .with {
                        $0.kind = .window
                        $0.credit = 1
                    })
                writeSocket()
            })
    }

    /// Ends both directions once. `notify` sends CLOSE first, best effort,
    /// when the end did not come from the gateway.
    private func closeOnQueue(notify: Bool) {
        guard !closed else { return }
        closed = true
        if notify { send(.with { $0.kind = .close }) }
        finish()
        listening?.resume(throwing: Self.failure("The relay tunnel closed."))
        listening = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        socket?.stateUpdateHandler = nil
        socket?.cancel()
        socket = nil
        incoming.removeAll()
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "DieterRelayTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Why a relay tunnel did not open: the gateway's CLOSE status, or the
/// stream's failure, as a gRPC status code.
public struct RelayTunnelFailure: Error, LocalizedError, Sendable {
    public let status: Int32
    public let message: String

    public init(status: Int32, message: String) {
        self.status = status
        self.message = message
    }

    public var errorDescription: String? { message }
}

extension RelayTunnel {
    /// Opens a tunnel to `daemonID` on `lane` (a `RelayLane` number) through
    /// the gateway behind `client`, authenticated by the user's session, and
    /// bridges it to a loopback port. Throws `RelayTunnelFailure` when the
    /// gateway answers CLOSE or the stream ends first.
    public static func open<Transport: ClientTransport>(
        client: GRPCClient<Transport>, sessionToken: String, clientVersion: String, daemonID: String, lane: Int
    ) async throws -> RelayTunnel {
        let (outgoing, sender) = AsyncStream.makeStream(of: Dieter_Gateway_V1_TunnelFrame.self)
        let call = Mutex<Task<Void, Never>?>(nil)
        let tunnel = RelayTunnel(
            send: { sender.yield($0) },
            finish: {
                sender.finish()
                // A gateway that keeps the stream open after CLOSE is cut off.
                let running = call.withLock { $0 }
                Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    running?.cancel()
                }
            })
        let opening = OneShot()
        var metadata = Metadata()
        metadata.addString("Bearer \(sessionToken)", forKey: "authorization")
        metadata.addString(clientVersion, forKey: "x-dieter-client-version")
        let open = Dieter_Gateway_V1_TunnelFrame.with {
            $0.kind = .open
            $0.daemonID = daemonID
            $0.lane = Dieter_Gateway_V1_RelayLane(rawValue: lane) ?? .command
        }
        let relay = Dieter_Gateway_V1_RelayService.Client(wrapping: client)
        let task = Task {
            do {
                try await relay.openTunnel(
                    metadata: metadata,
                    requestProducer: { writer in
                        try await writer.write(open)
                        for await frame in outgoing { try await writer.write(frame) }
                    },
                    onResponse: { response in
                        var opened = false
                        for try await frame in response.messages {
                            if opened {
                                tunnel.receive(frame)
                                continue
                            }
                            switch frame.kind {
                            case .opened:
                                opened = true
                                opening.resolve(nil)
                            case .close:
                                return opening.resolve(
                                    RelayTunnelFailure(
                                        status: frame.statusCode == 0 ? 14 : frame.statusCode,
                                        message: frame.statusMessage.isEmpty
                                            ? "The relay could not reach this machine." : frame.statusMessage))
                            default:
                                return opening.resolve(
                                    RelayTunnelFailure(
                                        status: 14, message: "The relay answered the tunnel with \(frame.kind)."))
                            }
                        }
                        opening.resolve(
                            RelayTunnelFailure(status: 14, message: "The relay ended the tunnel before it opened."))
                    })
                opening.resolve(RelayTunnelFailure(status: 14, message: "The relay ended the tunnel before it opened."))
            } catch let error as RPCError {
                opening.resolve(RelayTunnelFailure(status: Int32(error.code.rawValue), message: error.message))
            } catch {
                opening.resolve(RelayTunnelFailure(status: 14, message: (error as NSError).localizedDescription))
            }
            tunnel.streamEnded()
        }
        call.withLock { $0 = task }
        do {
            try await opening.wait()
            _ = try await tunnel.listen()
            return tunnel
        } catch {
            tunnel.close()
            task.cancel()
            throw error
        }
    }
}

/// The first outcome of opening a tunnel; later outcomes are ignored.
private final class OneShot: Sendable {
    private struct State {
        var outcome: Result<Void, any Error>?
        var waiter: CheckedContinuation<Void, any Error>?
    }
    private let state = Mutex(State())

    func resolve(_ failure: (any Error)?) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            guard state.outcome == nil else { return nil }
            state.outcome = failure.map { .failure($0) } ?? .success(())
            defer { state.waiter = nil }
            return state.waiter
        }
        if let failure { waiter?.resume(throwing: failure) } else { waiter?.resume() }
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let outcome = state.withLock { state -> Result<Void, any Error>? in
                if state.outcome == nil { state.waiter = continuation }
                return state.outcome
            }
            if let outcome { continuation.resume(with: outcome) }
        }
    }
}
