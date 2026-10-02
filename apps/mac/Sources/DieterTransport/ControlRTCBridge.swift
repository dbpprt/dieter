import Foundation
import Network
@preconcurrency import WebRTC
import DieterAPI

/// One loopback TLS socket ↔ one reliable RTC data channel. This adapter never
/// sees plaintext RPCs; the existing gRPC transport still verifies daemon TLS.
package final class ControlRTCBridge: NSObject, @unchecked Sendable {
    package struct CandidateSummary: Equatable, Sendable {
        package init(host: Int, srflx: Int, relay: Int) {
            self.host = host
            self.srflx = srflx
            self.relay = relay
        }
        package let host: Int
        package let srflx: Int
        package let relay: Int
    }

    package static func candidateSummary(in sdp: String) -> CandidateSummary {
        var host = 0, srflx = 0, relay = 0
        for line in sdp.split(separator: "\n") where line.hasPrefix("a=candidate:") {
            let fields = line.split(whereSeparator: \Character.isWhitespace)
            guard let marker = fields.firstIndex(of: "typ"), fields.indices.contains(marker + 1) else { continue }
            switch fields[marker + 1] {
            case "host": host += 1
            case "srflx": srflx += 1
            case "relay": relay += 1
            default: break
            }
        }
        return CandidateSummary(host: host, srflx: srflx, relay: relay)
    }

    private let queue = DispatchQueue(label: "dieter.control-rtc")
    private let callbackLock = NSLock()
    private var pendingCallbacks = 0
    private var callbacksRejected = false
    private let factory = RTCPeerConnectionFactory()
    private var peer: RTCPeerConnection!
    private var channel: RTCDataChannel?
    private var listener: NWListener?
    private var socket: NWConnection?
    private var closed = false
    private var opened = false
    private var gatheringComplete = false
    private var credits = 16
    private var reading = false
    private var writing = false
    private var incoming: [Data] = []
    private var accepted = false
    private var listenerContinuation: CheckedContinuation<Int, Error>?

    package init(configuration: Dieter_Gateway_V1_RTCConfiguration) throws {
        super.init()
        let config = RTCConfiguration()
        #if DEBUG
            if ProcessInfo.processInfo.environment["DIETER_TEST_FORCE_TURN"] == "1" {
                config.iceTransportPolicy = .relay
            }
        #endif
        config.iceServers = configuration.iceServers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        config.sdpSemantics = .unifiedPlan
        guard
            let peer = factory.peerConnection(
                with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
                delegate: self)
        else {
            throw Self.failure("Could not create WebRTC control connection")
        }
        self.peer = peer
        let options = RTCDataChannelConfiguration()
        options.isOrdered = true
        guard let channel = peer.dataChannel(forLabel: "dieter-control-tls-v1", configuration: options) else {
            peer.close()
            throw Self.failure("Could not create WebRTC control channel")
        }
        self.channel = channel
        channel.delegate = self
    }

    package func offer() async throws -> String {
        let description: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            peer.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) {
                description, error in
                if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: error ?? Self.failure("Missing control offer"))
                }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(description) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && !queue.sync(execute: { gatheringComplete || closed }) {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try Task.checkCancellation()
        guard let sdp = peer.localDescription?.sdp, sdp.utf8.count <= 65_536 else {
            throw Self.failure("Invalid control offer")
        }
        return sdp
    }

    package func connect(answer: String) async throws -> Int {
        guard answer.utf8.count <= 65_536 else { throw Self.failure("Control answer exceeds limit") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer)) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline && !queue.sync(execute: { opened || closed }) {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard queue.sync(execute: { opened && !closed }) else {
            throw Self.failure("WebRTC control connection timed out")
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.closed else {
                    continuation.resume(throwing: Self.failure("Control connection closed")); return
                }
                self.listener = listener
                self.listenerContinuation = continuation
                listener.stateUpdateHandler = { state in
                    guard let continuation = self.listenerContinuation else { return }
                    switch state {
                    case .ready:
                        self.listenerContinuation = nil
                        if let port = listener.port {
                            continuation.resume(returning: Int(port.rawValue))
                        } else {
                            continuation.resume(throwing: Self.failure("Missing control port"))
                        }
                    case .failed(let error):
                        self.listenerContinuation = nil; continuation.resume(throwing: error); self.closeOnQueue()
                    case .cancelled:
                        self.listenerContinuation = nil;
                        continuation.resume(throwing: Self.failure("Control listener closed"))
                    default: break
                    }
                }
                listener.newConnectionHandler = { socket in
                    guard !self.accepted && !self.closed else { socket.cancel(); return }
                    self.accepted = true
                    self.socket = socket
                    listener.cancel()
                    socket.stateUpdateHandler = { state in
                        switch state {
                        case .ready: self.readSocket(); self.writeSocket()
                        case .failed, .cancelled: self.closeOnQueue()
                        default: break
                        }
                    }
                    socket.start(queue: self.queue)
                }
                listener.start(queue: self.queue)
            }
        }
    }

    package func close() { queue.async { self.closeOnQueue() } }
    private func closeOnQueue() {
        guard !closed else { return }
        closed = true
        callbackLock.lock()
        callbacksRejected = true
        callbackLock.unlock()
        listenerContinuation?.resume(throwing: Self.failure("Control listener closed"))
        listenerContinuation = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        socket?.stateUpdateHandler = nil
        socket?.cancel(); socket = nil
        incoming.removeAll()
        channel?.delegate = nil
        channel?.close()
        peer?.delegate = nil
        peer?.close()
    }
    private func readSocket() {
        guard !closed, opened, credits > 0, !reading, let socket else { return }
        reading = true
        socket.receive(minimumIncompleteLength: 1, maximumLength: 16_383) { data, _, complete, error in
            self.reading = false
            guard !self.closed else { return }
            if let data, !data.isEmpty {
                var frame = Data([0]); frame.append(data)
                self.credits -= 1
                guard self.channel?.sendData(RTCDataBuffer(data: frame, isBinary: true)) == true else {
                    self.closeOnQueue(); return
                }
            }
            if complete || error != nil { self.closeOnQueue(); return }
            self.readSocket()
        }
    }
    private func writeSocket() {
        guard !closed, !writing, !incoming.isEmpty, let socket else { return }
        writing = true
        let data = incoming.removeFirst()
        socket.send(
            content: data,
            completion: .contentProcessed { error in
                self.writing = false
                guard !self.closed else { return }
                guard error == nil, self.channel?.sendData(RTCDataBuffer(data: Data([1]), isBinary: true)) == true
                else { self.closeOnQueue(); return }
                self.writeSocket()
            })
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "DieterControlRTC", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

extension ControlRTCBridge: RTCDataChannelDelegate {
    package func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let state = dataChannel.readyState
        queue.async {
            if state == .open { self.opened = true; self.readSocket() } else if state == .closed { self.closeOnQueue() }
        }
    }
    package func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        // Bound messages waiting to enter the serial socket queue as well as
        // the frame window inside it. A hostile peer must not enqueue unlimited Data.
        callbackLock.lock()
        guard !callbacksRejected else { callbackLock.unlock(); return }
        guard pendingCallbacks < 32 else {
            callbacksRejected = true
            callbackLock.unlock()
            close()
            return
        }
        pendingCallbacks += 1
        callbackLock.unlock()
        let data = buffer.data
        let binary = buffer.isBinary
        queue.async {
            self.callbackLock.lock()
            self.pendingCallbacks -= 1
            self.callbackLock.unlock()
            guard !self.closed else { return }
            guard binary, let kind = data.first, data.count <= 16_384 else { self.closeOnQueue(); return }
            if kind == 1 && data.count == 1 {
                guard self.credits < 16 else { self.closeOnQueue(); return }
                self.credits += 1; self.readSocket()
            } else if kind == 0 && data.count > 1 {
                guard self.incoming.count + (self.writing ? 1 : 0) < 16 else { self.closeOnQueue(); return }
                self.incoming.append(Data(data.dropFirst())); self.writeSocket()
            } else {
                self.closeOnQueue()
            }
        }
    }
}

extension ControlRTCBridge: RTCPeerConnectionDelegate {
    package func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    package func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    package func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    package func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    package func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed || newState == .closed { close() }
    }
    package func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { queue.async { self.gatheringComplete = true } }
    }
    package func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    package func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    package func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) { close() }
}
