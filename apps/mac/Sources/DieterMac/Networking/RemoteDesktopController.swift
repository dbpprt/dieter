import AppKit
import CryptoKit
import DieterAPI
import DieterCore
import Foundation
import OSLog
import Observation
import Security
import SwiftProtobuf
@preconcurrency import WebRTC

enum RemoteDesktopPhase: Equatable, Sendable {
    case idle
    case loading
    case disabled(String)
    case connecting
    case streaming
    case reconnecting
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Not connected"
        case .loading: "Checking machine…"
        case .disabled: "Screen sharing is off"
        case .connecting: "Connecting…"
        case .streaming: "Live"
        case .reconnecting: "Reconnecting…"
        case .failed: "Connection failed"
        }
    }
}

enum RemoteDesktopSessionTrust {
    enum Failure: LocalizedError {
        case invalidBinding
        case expiredBinding
        case invalidCertificate
        case invalidSignature

        var errorDescription: String? {
            switch self {
            case .invalidBinding:
                "The daemon returned a screen-sharing answer that was not bound to this request."
            case .expiredBinding: "The daemon screen-sharing binding has expired."
            case .invalidCertificate: "The enrolled daemon certificate is invalid."
            case .invalidSignature: "The daemon screen-sharing signature could not be verified."
            }
        }
    }

    static func verify(
        binding: Dieter_V1_RemoteDesktopSessionBinding,
        sessionID: String,
        clientNonce: String,
        offerSDP: String,
        answerSDP: String,
        daemonCertificatePEM: Data,
        now: Date = Date()
    ) throws {
        let offerHash = Data(SHA256.hash(data: Data(offerSDP.utf8)))
        guard binding.clientNonce == clientNonce,
            binding.offerSha256 == offerHash,
            binding.helperDtlsFingerprint == fingerprint(in: answerSDP),
            [2, 3].contains(binding.inputProtocolVersion),
            binding.inputEpoch.count == 16,
            !sessionID.isEmpty
        else { throw Failure.invalidBinding }
        guard let expires = timestamp(binding.expiresAt), expires > now else {
            throw Failure.expiredBinding
        }
        guard let certificate = certificate(fromPEM: daemonCertificatePEM),
            let publicKey = SecCertificateCopyKey(certificate)
        else { throw Failure.invalidCertificate }
        let message = bindingMessage(
            sessionID: sessionID, nonce: clientNonce,
            fingerprint: binding.helperDtlsFingerprint, expiresAt: binding.expiresAt,
            offerHash: offerHash, controlGranted: binding.controlGranted,
            displayID: binding.displayID, inputProtocolVersion: binding.inputProtocolVersion,
            inputEpoch: binding.inputEpoch
        )
        var keyError: Unmanaged<CFError>?
        guard let rawKey = SecKeyCopyExternalRepresentation(publicKey, &keyError) as Data?,
            let signingKey = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey),
            signingKey.isValidSignature(binding.daemonSignature, for: message)
        else {
            throw Failure.invalidSignature
        }
    }

    static func bindingMessage(
        sessionID: String,
        nonce: String,
        fingerprint: String,
        expiresAt: String,
        offerHash: Data,
        controlGranted: Bool,
        displayID: String,
        inputProtocolVersion: UInt32,
        inputEpoch: Data
    ) -> Data {
        let encodedHash = offerHash.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Data(
            [
                "dieter-remote-desktop-v\(inputProtocolVersion)", sessionID, nonce, fingerprint, expiresAt, encodedHash,
                controlGranted ? "true" : "false", displayID, String(inputProtocolVersion),
                inputEpoch.base64URLEncodedString(),
            ].joined(separator: "\n").utf8)
    }

    static func fingerprint(in sdp: String) -> String {
        for line in sdp.split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("a=fingerprint:") {
                return String(value.dropFirst("a=fingerprint:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    private static func timestamp(_ value: String) -> Date? {
        DieterTimestamp.date(from: value)
    }

    private static func certificate(fromPEM pem: Data) -> SecCertificate? {
        guard let text = String(data: pem, encoding: .utf8) else { return nil }
        let body =
            text
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let der = Data(base64Encoded: body) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }
}

extension Data {
    fileprivate func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
@Observable
final class RemoteDesktopController {
    private static let mediaLogger = Logger(
        subsystem: "com.dbpprt.dieter.mac", category: "remote-desktop-media")
    var phase: RemoteDesktopPhase = .idle
    var capabilities = Dieter_V1_RemoteDesktopCapabilities()
    var settings = Dieter_V1_RemoteDesktopSettings()
    var routeLabel = ""
    var machineName = ""
    var errorMessage: String?
    var sessionState = Dieter_V1_RemoteDesktopSessionState()
    var mediaRouteLabel = "Negotiating media"
    var remoteCursor: NSCursor = .arrow
    var remoteCursorState = Dieter_V1_RemoteDesktopCursor()
    var inputFocused = false
    var textInputMode = false
    var quality: Dieter_V1_RemoteDesktopQuality = .auto
    private var cursorCache: [String: NSCursor] = [:]
    private var hostChannel: RTCDataChannel?
    private var hostChannelDelegate: RemoteDesktopDataChannelDelegate?
    private let feedbackPump = RemoteDesktopFeedbackPump()
    private var eventOrdinal: UInt64 = 0
    private var previousStatistics: [String: Double] = [:]
    private var previousStatisticsTime = Date()
    var controlActive = false
    var controlUnavailableReason = ""
    @ObservationIgnored var onUserActivity: @MainActor () -> Void = {}

    let renderer = RemoteDesktopMetalView(frame: .zero)
    @ObservationIgnored private let frameObserver = RemoteDesktopFrameObserver()
    private var presentedGeneration: UInt64 = 0

    private let factory = RTCPeerConnectionFactory(
        encoderFactory: RTCDefaultVideoEncoderFactory(),
        decoderFactory: RemoteDesktopDecoderFactory()
    )
    private let delegate = RemoteDesktopPeerDelegate()
    private var peerConnection: RTCPeerConnection?
    private var connection: RemoteDesktopSignalingConnection?
    private var request: Dieter_V1_StartRemoteDesktopRequest?
    private var binding: Dieter_V1_RemoteDesktopSessionBinding?
    private var answerSDP: String?
    var immediatePlayoutNegotiated: Bool {
        answerSDP?.contains("http://www.webrtc.org/experiments/rtp-hdrext/playout-delay") == true
    }
    private var remoteDescriptionApplied = false
    private var pendingLocalCandidates: [RTCIceCandidate] = []
    private var pendingRemoteCandidates: [RTCIceCandidate] = []
    private var sessionID = ""
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    private var signalingTask: Task<Void, Never>?
    private var leaseTask: Task<Void, Never>?
    private var statisticsTask: Task<Void, Never>?
    private var videoTrack: RTCVideoTrack?
    private var pointerChannel: RTCDataChannel?
    private var stateChannel: RTCDataChannel?
    private var pointerChannelDelegate: RemoteDesktopDataChannelDelegate?
    private var stateChannelDelegate: RemoteDesktopDataChannelDelegate?
    private var pointerSequence: UInt64 = 0
    private var stateSequence: UInt64 = 0
    private var pendingPointer: (Int32, Int32)?
    private var pointerFlushTask: Task<Void, Never>?
    private var signalingReceiveFailure: String?
    private var viewport = CGSize(width: 1920, height: 1080)
    private var viewportTask: Task<Void, Never>?
    private var configurationTask: Task<Void, Never>?
    private var desiredConfiguration = Dieter_V1_RemoteDesktopStreamConfiguration()
    private var configurationPending = false
    private var refreshPending = false

    init() {
        delegate.owner = self
        frameObserver.onReady = { [weak self] token, display in
            Task { @MainActor [weak self] in
                guard let self, self.owns(token), self.sessionState.displayGeneration == display else { return }
                self.presentedGeneration = display
                self.phase = .streaming
                self.updateControlReadiness()
            }
        }
        renderer.onFramePresented = { [observer = frameObserver] frame in observer.renderFrame(frame) }
        renderer.onFailure = { [weak self] message in self?.fail(message: message) }
    }

    @discardableResult
    func connect(
        machineName: String, makeConnection: @escaping @MainActor () async throws -> RemoteDesktopSignalingConnection
    ) -> Task<Void, Never> {
        disconnect()
        phase = .loading
        errorMessage = nil
        self.machineName = machineName
        let token = generation
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.owns(token) { self.connectTask = nil } }
            do {
                let connection = try await makeConnection()
                guard self.owns(token) else { connection.shutdown(); return }
                self.connection = connection
                self.routeLabel = connection.routeLabel
                let settings = try await connection.rpc.remoteDesktopSettings()
                guard self.owns(token) else { return }
                self.settings = settings
                let capabilities = try await connection.rpc.remoteDesktopCapabilities()
                guard self.owns(token) else { return }
                self.capabilities = capabilities
                guard settings.enabled else { self.phase = .disabled(capabilities.unavailableReason); return }
                try await self.startPeerSession(generation: token)
            } catch {
                guard self.owns(token) else { return }
                if DieterRPCFailure.isCancellation(error) { self.disconnect() } else { self.fail(error) }
            }
        }
        connectTask = task
        return task
    }

    func enableAndConnect() {
        guard let connection, connectTask == nil else { return }
        onUserActivity()
        phase = .loading
        let token = generation
        connectTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.owns(token) { self.connectTask = nil } }
            do {
                let settings = try await connection.rpc.updateRemoteDesktopSettings(enabled: true, controlEnabled: true)
                guard self.owns(token) else { return }
                self.settings = settings
                let capabilities = try await connection.rpc.remoteDesktopCapabilities()
                guard self.owns(token) else { return }
                self.capabilities = capabilities
                try await self.startPeerSession(generation: token)
            } catch {
                guard self.owns(token) else { return }
                self.fail(error)
            }
        }
    }

    private func owns(_ token: UInt64) -> Bool { generation == token && !Task.isCancelled }
    fileprivate func owns(peer: RTCPeerConnection) -> Bool { peerConnection === peer }
    fileprivate func owns(channel: RTCDataChannel) -> Bool {
        pointerChannel === channel || stateChannel === channel || hostChannel === channel
    }

    func disconnect() {
        generation &+= 1
        connectTask?.cancel(); connectTask = nil
        releaseAllInput()
        signalingTask?.cancel()
        leaseTask?.cancel()
        statisticsTask?.cancel()
        feedbackPump.stop()
        viewportTask?.cancel(); viewportTask = nil
        configurationTask?.cancel(); configurationTask = nil
        configurationPending = false; refreshPending = false
        pointerFlushTask?.cancel()
        signalingTask = nil
        leaseTask = nil
        statisticsTask = nil
        pointerFlushTask = nil
        let previousConnection = connection
        let previousSessionID = sessionID
        if !previousSessionID.isEmpty {
            Task {
                try? await previousConnection?.rpc.closeRemoteDesktop(sessionID: previousSessionID)
                previousConnection?.shutdown()
            }
        } else {
            previousConnection?.shutdown()
        }
        videoTrack?.remove(renderer)
        frameObserver.reset(); renderer.reset(); presentedGeneration = 0
        videoTrack = nil
        pointerChannel?.close()
        stateChannel?.close()
        hostChannel?.close(); hostChannel = nil; hostChannelDelegate = nil
        eventOrdinal = 0; inputFocused = false
        previousStatistics = [:]; cursorCache = [:]
        sessionState = .init(); remoteCursorState = .init(); remoteCursor = .arrow
        pointerChannel = nil
        stateChannel = nil
        pointerChannelDelegate = nil
        stateChannelDelegate = nil
        peerConnection?.close()
        peerConnection = nil
        connection = nil
        request = nil
        binding = nil
        answerSDP = nil
        remoteDescriptionApplied = false
        pendingLocalCandidates.removeAll()
        pendingRemoteCandidates.removeAll()
        signalingReceiveFailure = nil
        sessionID = ""
        pointerSequence = 0
        stateSequence = 0
        pendingPointer = nil
        controlActive = false
        controlTransferPending = false; controlTransferError = ""
        routeLabel = ""
        if case .failed = phase {} else { phase = .idle }
    }

    private func startPeerSession(generation token: UInt64) async throws {
        guard owns(token) else { throw CancellationError() }
        if let message = renderer.initializationFailure {
            throw NSError(domain: "DieterScreens", code: 6, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard capabilities.ready else {
            throw NSError(
                domain: "DieterScreens", code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey: capabilities.unavailableReason.isEmpty
                        ? "Screen sharing is not ready on this machine." : capabilities.unavailableReason
                ]
            )
        }
        guard let connection else { return }
        phase = .connecting
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherContinually
        configuration.iceServers = connection.rtcConfiguration.iceServers.map {
            RTCIceServer(
                urlStrings: $0.urls,
                username: $0.username.isEmpty ? nil : $0.username,
                credential: $0.credential.isEmpty ? nil : $0.credential
            )
        }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard
            let peer = factory.peerConnection(
                with: configuration, constraints: constraints, delegate: delegate)
        else {
            throw NSError(
                domain: "DieterScreens", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "WebRTC could not create a peer connection."])
        }
        peerConnection = peer
        let pointerConfiguration = RTCDataChannelConfiguration()
        pointerConfiguration.isOrdered = false
        pointerConfiguration.maxRetransmits = 0
        pointerChannel = peer.dataChannel(forLabel: "dieter-pointer-v2", configuration: pointerConfiguration)
        let stateConfiguration = RTCDataChannelConfiguration()
        stateConfiguration.isOrdered = true
        stateChannel = peer.dataChannel(forLabel: "dieter-input-state-v2", configuration: stateConfiguration)
        let pointerDelegate = RemoteDesktopDataChannelDelegate(owner: self)
        let stateDelegate = RemoteDesktopDataChannelDelegate(owner: self)
        pointerChannelDelegate = pointerDelegate
        stateChannelDelegate = stateDelegate
        hostChannel = peer.dataChannel(forLabel: "dieter-session-v2", configuration: stateConfiguration)
        hostChannelDelegate = RemoteDesktopDataChannelDelegate(owner: self)
        hostChannel?.delegate = hostChannelDelegate
        pointerChannel?.delegate = pointerDelegate
        stateChannel?.delegate = stateDelegate
        let transceiver = RTCRtpTransceiverInit()
        transceiver.direction = .recvOnly
        guard let videoTransceiver = peer.addTransceiver(of: .video, init: transceiver) else {
            throw NSError(
                domain: "DieterScreens", code: 7,
                userInfo: [NSLocalizedDescriptionKey: "WebRTC could not create a receive-only video track."]
            )
        }
        let h264 = factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs
            .filter { $0.name.caseInsensitiveCompare("H264") == .orderedSame }
        guard !h264.isEmpty else {
            throw NSError(
                domain: "DieterScreens", code: 12,
                userInfo: [
                    NSLocalizedDescriptionKey: "This Mac does not provide a compatible H.264 WebRTC decoder."
                ])
        }
        try videoTransceiver.setCodecPreferences(h264, error: ())
        let offer = try await createOffer(peer, constraints: constraints)
        guard owns(token), peerConnection === peer else { throw CancellationError() }
        try await setLocalDescription(offer, on: peer)
        guard owns(token), peerConnection === peer else { throw CancellationError() }

        var request = Dieter_V1_StartRemoteDesktopRequest()
        request.clientNonce = UUID().uuidString.lowercased()
        request.inputProtocolVersion = capabilities.supportedInputProtocolVersions.contains(3) ? 3 : 2
        request.clientName = "Mac"
        request.rtcConfiguration = connection.rtcConfiguration
        request.displayID =
            capabilities.displays.first(where: \.primary)?.id ?? capabilities.displays.first?.id
            ?? "primary"
        request.maxFps = 60
        request.maxBitrateKbps = 12_000
        request.maxWidth = Int32(viewport.width)
        request.maxHeight = Int32(viewport.height)
        request.quality = quality
        request.control =
            settings.controlEnabled && capabilities.controlSupported
            && capabilities.controlPermission == "granted"
        controlUnavailableReason =
            settings.controlEnabled && !request.control
            ? "Accessibility permission is required on the host" : ""
        var description = Dieter_V1_RemoteDesktopSessionDescription()
        description.type = "offer"
        description.sdp = offer.sdp
        request.offer = description
        self.request = request
        desiredConfiguration = .init()
        desiredConfiguration.displayID = request.displayID
        desiredConfiguration.maxWidth = request.maxWidth; desiredConfiguration.maxHeight = request.maxHeight
        desiredConfiguration.maxFps = request.maxFps; desiredConfiguration.maxBitrateKbps = request.maxBitrateKbps
        desiredConfiguration.quality = request.quality
        startSignaling(connection: connection, request: request)
    }

    private func startSignaling(
        connection: RemoteDesktopSignalingConnection, request: Dieter_V1_StartRemoteDesktopRequest
    ) {
        signalingTask?.cancel()
        let token = generation
        signalingTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                do {
                    guard self?.owns(token) == true else { return }
                    self?.signalingReceiveFailure = nil
                    try await connection.rpc.startRemoteDesktop(request) { [weak self] signal in
                        guard let self else { throw CancellationError() }
                        do {
                            try await self.receive(signal, generation: token)
                        } catch {
                            await self.rememberSignalingReceiveFailure(
                                DieterRPCFailure.message(for: error), generation: token)
                            throw error
                        }
                    }
                    if !Task.isCancelled {
                        throw NSError(
                            domain: "DieterScreens", code: 8,
                            userInfo: [NSLocalizedDescriptionKey: "Screen-sharing signaling ended."])
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard self?.owns(token) == true else { return }
                    let failureMessage = self?.signalingReceiveFailure ?? DieterRPCFailure.message(for: error)
                    attempt += 1
                    guard attempt <= 2, self?.peerConnection != nil else {
                        self?.fail(message: failureMessage)
                        return
                    }
                    self?.setReconnecting()
                    try? await DieterTaskSleep.seconds(Double(attempt))
                }
            }
        }
    }

    private func receive(_ signal: Dieter_V1_RemoteDesktopSignal, generation token: UInt64) async throws {
        guard owns(token) else { throw CancellationError() }
        if sessionID.isEmpty {
            sessionID = signal.sessionID
            flushLocalCandidates()
            startLease()
        } else if signal.sessionID != sessionID {
            throw RemoteDesktopSessionTrust.Failure.invalidBinding
        }
        switch signal.payload {
        case .binding(let value):
            binding = value
            try await applyVerifiedAnswerIfReady()
        case .description_p(let value):
            guard value.type == "answer" else { return }
            answerSDP = value.sdp
            try await applyVerifiedAnswerIfReady()
        case .candidate(let value):
            let candidate = RTCIceCandidate(
                sdp: value.candidate, sdpMLineIndex: value.sdpMlineIndex,
                sdpMid: value.sdpMid.isEmpty ? nil : value.sdpMid)
            if remoteDescriptionApplied {
                try await addIceCandidate(candidate)
            } else {
                guard pendingRemoteCandidates.count < 256 else { throw CancellationError() }
                pendingRemoteCandidates.append(candidate)
            }
        case .state(let value):
            if value.phase == "streaming" { phase = presentedGeneration > 0 ? .streaming : .connecting }
            if value.phase == "reconnecting" { phase = .reconnecting }
            if value.phase == "closed", phase != .idle {
                peerConnection?.close()
                peerConnection = nil
                throw NSError(
                    domain: "DieterScreens", code: 9,
                    userInfo: [
                        NSLocalizedDescriptionKey: value.reason.isEmpty
                            ? "The screen-sharing session closed." : value.reason
                    ])
            }
        case .error(let value):
            if !value.recoverable {
                peerConnection?.close()
                peerConnection = nil
            }
            throw NSError(
                domain: "DieterScreens", code: 10, userInfo: [NSLocalizedDescriptionKey: value.message])
        case .leaseHeartbeat, .none:
            break
        }
    }

    private func applyVerifiedAnswerIfReady() async throws {
        guard !remoteDescriptionApplied,
            let connection, let request, let binding, let answerSDP
        else { return }
        try RemoteDesktopSessionTrust.verify(
            binding: binding, sessionID: sessionID, clientNonce: request.clientNonce,
            offerSDP: request.offer.sdp, answerSDP: answerSDP,
            daemonCertificatePEM: connection.daemonCertificatePEM
        )
        guard binding.controlGranted == request.control, binding.displayID == request.displayID,
            binding.inputProtocolVersion == request.inputProtocolVersion
        else {
            throw RemoteDesktopSessionTrust.Failure.invalidBinding
        }
        guard let peerConnection else { throw CancellationError() }
        let token = generation
        try await setRemoteDescription(
            RTCSessionDescription(type: .answer, sdp: answerSDP), on: peerConnection)
        guard owns(token), self.peerConnection === peerConnection else { throw CancellationError() }
        remoteDescriptionApplied = true
        updateControlReadiness()
        let candidates = pendingRemoteCandidates
        pendingRemoteCandidates.removeAll()
        for candidate in candidates {
            guard owns(token), self.peerConnection === peerConnection else { throw CancellationError() }
            try await addIceCandidate(candidate)
        }
    }

    private func startLease() {
        leaseTask?.cancel()
        let token = generation
        leaseTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await DieterTaskSleep.seconds(5)
                guard !Task.isCancelled, let self, let connection = self.connection, !self.sessionID.isEmpty
                else { return }
                var signal = Dieter_V1_RemoteDesktopSignal()
                signal.sessionID = self.sessionID
                signal.leaseHeartbeat = Google_Protobuf_Empty()
                do { try await connection.rpc.sendRemoteDesktopSignal(signal) } catch {
                    guard self.owns(token) else { return }
                    self.setReconnecting()
                }
            }
        }
    }

    fileprivate func generated(candidate: RTCIceCandidate) {
        guard !sessionID.isEmpty else {
            guard pendingLocalCandidates.count < 256 else { return }
            pendingLocalCandidates.append(candidate)
            return
        }
        send(candidate: candidate)
    }

    private func flushLocalCandidates() {
        let candidates = pendingLocalCandidates
        pendingLocalCandidates.removeAll()
        for candidate in candidates { send(candidate: candidate) }
    }

    private func send(candidate: RTCIceCandidate) {
        guard let connection, !sessionID.isEmpty else { return }
        var value = Dieter_V1_RemoteDesktopICECandidate()
        value.candidate = candidate.sdp
        value.sdpMid = candidate.sdpMid ?? ""
        value.sdpMlineIndex = candidate.sdpMLineIndex
        var signal = Dieter_V1_RemoteDesktopSignal()
        signal.sessionID = sessionID
        signal.candidate = value
        Task { try? await connection.rpc.sendRemoteDesktopSignal(signal) }
    }

    fileprivate func received(track: RTCVideoTrack) {
        if videoTrack?.isEqual(track) == true { return }
        videoTrack?.remove(renderer)
        videoTrack = track
        track.add(renderer)
    }

    fileprivate func connectionStateChanged(_ state: RTCPeerConnectionState) {
        switch state {
        case .connected:
            phase = presentedGeneration > 0 ? .streaming : .connecting
            startStatistics()
        case .disconnected:
            releaseAllInput()
            phase = .reconnecting
        case .failed:
            fail(
                NSError(
                    domain: "DieterScreens", code: 11,
                    userInfo: [NSLocalizedDescriptionKey: "The WebRTC connection failed."]))
        case .closed:
            if case .failed = phase { return }
            if phase != .idle { phase = .idle }
        default: break
        }
    }

    private func setReconnecting() { if phase != .idle { phase = .reconnecting } }

    func sendPointerMove(x: CGFloat, y: CGFloat) {
        onUserActivity()
        guard controlActive else { return }
        pendingPointer = (normalized(x), normalized(y))
        guard pointerFlushTask == nil else { return }
        pointerFlushTask = Task { [weak self] in
            try? await DieterTaskSleep.seconds(0.008)
            guard !Task.isCancelled, let self else { return }
            self.pointerFlushTask = nil
            guard let point = self.pendingPointer else { return }
            self.pendingPointer = nil
            var move = Dieter_V1_RemoteDesktopPointerMove()
            move.normalizedX = point.0
            move.normalizedY = point.1
            self.sendPointer(.pointerMove(move))
        }
    }

    func sendPointerButton(
        _ button: Dieter_V1_RemoteDesktopPointerButton.Button, down: Bool,
        clickCount: Int, x: CGFloat, y: CGFloat, modifiers: NSEvent.ModifierFlags
    ) {
        onUserActivity()
        var value = Dieter_V1_RemoteDesktopPointerButton()
        value.button = button
        value.down = down
        value.clickCount = Int32(max(0, min(3, clickCount)))
        value.normalizedX = normalized(x)
        value.normalizedY = normalized(y)
        value.modifiers = Self.modifiers(modifiers)
        sendState(.pointerButton(value))
    }

    func sendScroll(
        deltaX: CGFloat, deltaY: CGFloat, precise: Bool, modifiers: NSEvent.ModifierFlags, phase: NSEvent.Phase = [],
        momentumPhase: NSEvent.Phase = []
    ) {
        onUserActivity()
        var value = Dieter_V1_RemoteDesktopScroll()
        value.deltaX = Int32(clamping: Int(deltaX.rounded()))
        value.deltaY = Int32(clamping: Int(deltaY.rounded()))
        value.precise = precise
        value.preciseDeltaX = deltaX; value.preciseDeltaY = deltaY
        value.phase = RemoteDesktopScrollPhases.scroll(phase)
        value.momentumPhase = RemoteDesktopScrollPhases.momentum(momentumPhase)
        value.modifiers = Self.modifiers(modifiers)
        sendState(.scroll(value))
    }

    func sendKey(code: UInt16, down: Bool, repeat isRepeat: Bool, modifiers: NSEvent.ModifierFlags) {
        onUserActivity()
        var value = Dieter_V1_RemoteDesktopKey()
        value.keyCode = UInt32(code)
        value.physicalKey = RemoteDesktopKeyMap.macToHID[code] ?? 0
        value.down = down
        value.repeat = isRepeat
        value.modifiers = Self.modifiers(modifiers)
        sendState(.key(value))
    }

    func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        onUserActivity()
        guard text.utf8.count <= 8192 else { fail(message: "Text input is limited to 8 KB per insertion."); return }
        var chunk = ""
        @MainActor func sendChunk() {
            guard !chunk.isEmpty else { return }
            var value = Dieter_V1_RemoteDesktopText(); value.text = chunk
            sendState(.text(value)); chunk = ""
        }
        guard !text.contains(where: { String($0).utf16.count > 512 }) else {
            fail(message: "A text input character exceeds the supported size."); return
        }
        for character in text {
            if chunk.utf16.count + String(character).utf16.count > 512 { sendChunk() }
            chunk.append(character)
        }
        sendChunk()
    }

    func releaseAllInput() {
        pendingPointer = nil
        pointerFlushTask?.cancel(); pointerFlushTask = nil
        guard controlActive else { return }
        sendState(.releaseAll(Dieter_V1_RemoteDesktopReleaseAll()))
    }

    private func sendPointer(_ payload: Dieter_V1_RemoteDesktopInput.OneOf_Payload) {
        guard let channel = pointerChannel, channel.readyState == .open, channel.bufferedAmount < 65_536,
            let binding
        else { return }
        pointerSequence &+= 1
        send(payload, sequence: pointerSequence, binding: binding, channel: channel)
    }

    private func sendState(_ payload: Dieter_V1_RemoteDesktopInput.OneOf_Payload) {
        guard controlActive else { return }
        guard let channel = stateChannel, channel.readyState == .open,
            channel.bufferedAmount < 65_536, let binding
        else {
            controlActive = false; fail(message: "Remote input connection stalled. Reconnect to resume control.");
            return
        }
        pendingPointer = nil
        stateSequence &+= 1
        send(payload, sequence: stateSequence, binding: binding, channel: channel)
    }

    private func send(
        _ payload: Dieter_V1_RemoteDesktopInput.OneOf_Payload, sequence: UInt64,
        binding: Dieter_V1_RemoteDesktopSessionBinding, channel: RTCDataChannel
    ) {
        var input = Dieter_V1_RemoteDesktopInput()
        input.controlGeneration = sessionState.controlGeneration
        input.protocolVersion = binding.inputProtocolVersion
        input.inputEpoch = binding.inputEpoch
        input.sequence = sequence
        eventOrdinal &+= 1
        input.eventOrdinal = eventOrdinal
        input.stateBarrier = stateSequence
        input.displayGeneration = sessionState.displayGeneration
        input.payload = payload
        guard let data = try? input.serializedData(), data.count <= 4_096 else { return }
        if !channel.sendData(RTCDataBuffer(data: data, isBinary: true)), channel === stateChannel {
            controlActive = false
            fail(message: "Remote input could not be delivered. Reconnect to resume control.")
        }
    }

    private func normalized(_ value: CGFloat) -> Int32 {
        Int32((max(0, min(1, value)) * 1_000_000).rounded())
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.shift) { value |= 1 }
        if flags.contains(.control) { value |= 2 }
        if flags.contains(.option) { value |= 4 }
        if flags.contains(.command) { value |= 8 }
        if flags.contains(.capsLock) { value |= 16 }
        if flags.contains(.function) { value |= 32 }
        return value
    }

    fileprivate func receiveHost(_ event: Dieter_V1_RemoteDesktopHostEvent) {
        switch event.payload {
        case .state(let state): applySessionState(state)
        case .cursor(let cursor):
            guard cursor.displayGeneration == sessionState.displayGeneration else { return }
            if !cursor.png.isEmpty, cursor.png.count <= 262_144,
                cursor.width > 0, cursor.width <= 256, cursor.height > 0, cursor.height <= 256,
                let image = NSImage(data: cursor.png)
            {
                image.size = NSSize(width: cursor.width, height: cursor.height)
                let value = NSCursor(image: image, hotSpot: NSPoint(x: cursor.hotspotX, y: cursor.hotspotY))
                if cursorCache.count >= 32 { cursorCache.removeAll(keepingCapacity: true) }
                cursorCache[cursor.shapeID] = value
            }
            if let value = cursorCache[cursor.shapeID] { remoteCursor = value }
            remoteCursorState = cursor
        case .inputAck(let ordinal): sessionState.lastInputOrdinal = ordinal
        case nil: break
        }
    }

    private func applySessionState(_ received: Dieter_V1_RemoteDesktopSessionState) {
        // RPC responses and the reliable host channel can cross in flight.
        guard received.displayGeneration >= sessionState.displayGeneration else { return }
        var state = received
        if state.displayGeneration != sessionState.displayGeneration {
            releaseAllInput()
            remoteCursorState = .init()
            presentedGeneration = 0
            phase = .connecting
        } else if state.mediaGeneration < sessionState.mediaGeneration {
            state.mediaGeneration = sessionState.mediaGeneration
            state.mediaTimestamp = sessionState.mediaTimestamp
        }
        if state.controlGeneration < sessionState.controlGeneration {
            state.controlGeneration = sessionState.controlGeneration
            state.controlActive = sessionState.controlActive
            state.controllerName = sessionState.controllerName
        }
        sessionState = state
        if state.mediaGeneration > 0, state.mediaGeneration == state.displayGeneration {
            frameObserver.expect(
                token: generation, generation: state.mediaGeneration, timestamp: state.mediaTimestamp)
        }
        updateControlReadiness()
    }

    fileprivate func updateControlReadiness() {
        controlActive =
            binding?.controlGranted == true && (binding?.inputProtocolVersion != 3 || sessionState.controlActive)
            && pointerChannel?.readyState == .open
            && stateChannel?.readyState == .open && hostChannel?.readyState == .open
            && sessionState.displayGeneration > 0 && presentedGeneration == sessionState.displayGeneration
        feedbackPump.input(active: controlActive && inputFocused && NSApp.isActive)
    }

    var canTransferControl: Bool { binding?.inputProtocolVersion == 3 && binding?.controlGranted == true }
    var controlTransferPending = false
    var controlTransferError = ""

    func transferControl(take: Bool) {
        guard canTransferControl, !controlTransferPending, let connection else { return }
        let token = generation
        controlTransferPending = true; controlTransferError = ""
        releaseAllInput()
        Task { [weak self] in
            guard let self else { return }
            do {
                let state = try await connection.rpc.setRemoteDesktopControl(sessionID: self.sessionID, take: take)
                guard self.owns(token) else { return }
                self.applySessionState(state)
            } catch {
                if self.owns(token) { self.controlTransferError = error.localizedDescription }
            }
            if self.owns(token) { self.controlTransferPending = false }
        }
    }

    func setViewport(_ size: CGSize, scale: CGFloat) {
        guard size.width > 0, size.height > 0 else { return }
        let value = CGSize(
            width: max(640, min(3840, ceil(size.width * scale / 160) * 160)),
            height: max(360, min(2160, ceil(size.height * scale / 90) * 90)))
        guard value != viewport else { return }
        viewport = value
        viewportTask?.cancel()
        let token = generation
        viewportTask = Task { [weak self] in
            try? await DieterTaskSleep.seconds(0.35)
            guard !Task.isCancelled, let self, self.owns(token), self.viewport == value,
                !self.sessionID.isEmpty, let connection = self.connection
            else { return }
            self.desiredConfiguration.maxWidth = Int32(value.width)
            self.desiredConfiguration.maxHeight = Int32(value.height)
            self.configurationPending = true
            self.submitConfiguration(connection: connection)

        }
    }

    func configure(displayID: String? = nil, quality: Dieter_V1_RemoteDesktopQuality? = nil, refresh: Bool = false) {
        guard let connection, !sessionID.isEmpty else { return }
        onUserActivity()
        releaseAllInput()
        if let displayID { desiredConfiguration.displayID = displayID; configurationPending = true }
        if let quality { desiredConfiguration.quality = quality; self.quality = quality; configurationPending = true }
        refreshPending = refreshPending || refresh
        submitConfiguration(connection: connection)
    }

    private func submitConfiguration(connection: RemoteDesktopSignalingConnection) {
        guard configurationTask == nil else { return }
        let token = generation
        configurationTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.owns(token) { self.configurationTask = nil } }
            while self.owns(token), self.configurationPending || self.refreshPending {
                var update = Dieter_V1_UpdateRemoteDesktopSessionRequest()
                update.sessionID = self.sessionID; update.refresh = self.refreshPending
                if self.configurationPending { update.configuration = self.desiredConfiguration }
                self.configurationPending = false; self.refreshPending = false
                do {
                    let state = try await connection.rpc.updateRemoteDesktopSession(update)
                    guard self.owns(token) else { return }
                    self.applySessionState(state)
                } catch {
                    guard self.owns(token) else { return }
                    self.fail(error); return
                }
            }
        }
    }

    private func startStatistics() {
        statisticsTask?.cancel()
        previousStatistics = [:]; previousStatisticsTime = Date()
        var initial = Dieter_V1_RemoteDesktopReceiverFeedback()
        initial.protocolVersion = 2; initial.inputEpoch = binding?.inputEpoch ?? Data()
        feedbackPump.start(channel: hostChannel, initial: initial)
        let token = generation
        statisticsTask = Task { [weak self] in
            var emptyIntervals = 0
            while !Task.isCancelled {
                try? await DieterTaskSleep.seconds(0.5)
                guard !Task.isCancelled, let self, self.owns(token), let peer = self.peerConnection else { return }
                let report = await peer.statistics()
                guard self.owns(token) else { return }
                var inbound: [String: NSObject] = [:]
                var candidate: [String: NSObject] = [:]
                for statistic in report.statistics.values {
                    if statistic.type == "inbound-rtp", statistic.values["kind"] as? String == "video" {
                        inbound = statistic.values
                    } else if statistic.type == "candidate-pair", statistic.values["nominated"] as? Bool == true,
                        statistic.values["state"] as? String == "succeeded"
                    {
                        candidate = statistic.values
                    }
                }
                let now = Date(), elapsed = max(0.001, now.timeIntervalSince(self.previousStatisticsTime))
                var current: [String: Double] = [:]
                for key in [
                    "framesDecoded", "totalDecodeTime", "jitterBufferEmittedCount", "jitterBufferDelay", "packetsLost",
                    "packetsReceived",
                ] {
                    current[key] = (inbound[key] as? NSNumber)?.doubleValue ?? 0
                }
                let previous = self.previousStatistics
                current["framesPresented"] = Double(self.renderer.framesPresented)
                current["renderMilliseconds"] = self.renderer.totalRenderMilliseconds
                current["timedPresentations"] = Double(self.renderer.timedPresentations)
                func delta(_ key: String) -> Double { max(0, (current[key] ?? 0) - (previous[key] ?? 0)) }
                let frames = delta("framesDecoded")
                var feedback = Dieter_V1_RemoteDesktopReceiverFeedback()
                feedback.protocolVersion = 2; feedback.inputEpoch = self.binding?.inputEpoch ?? Data()
                feedback.framesPerSecond = delta("framesPresented") / elapsed
                feedback.decodeMs = frames > 0 ? delta("totalDecodeTime") * 1000 / frames : 0
                let emitted = delta("jitterBufferEmittedCount"), presented = delta("timedPresentations")
                feedback.jitterBufferMs = emitted > 0 ? delta("jitterBufferDelay") * 1000 / emitted : 0
                feedback.renderMs = presented > 0 ? delta("renderMilliseconds") / presented : 0
                feedback.jitterMs = ((inbound["jitter"] as? NSNumber)?.doubleValue ?? 0) * 1000
                feedback.rttMs = ((candidate["currentRoundTripTime"] as? NSNumber)?.doubleValue ?? 0) * 1000
                feedback.lossFraction = delta("packetsLost") / max(1, delta("packetsLost") + delta("packetsReceived"))
                feedback.inputActive = self.controlActive && self.inputFocused && NSApp.isActive
                feedback.renderedFrames = UInt32(clamping: self.renderer.framesPresented)
                self.feedbackPump.update(feedback)
                self.feedbackPump.input(active: self.controlActive && self.inputFocused && NSApp.isActive)
                if let localID = candidate["localCandidateId"] as? String,
                    let remoteID = candidate["remoteCandidateId"] as? String
                {
                    let types = [localID, remoteID].compactMap {
                        report.statistics[$0]?.values["candidateType"] as? String
                    }
                    self.mediaRouteLabel = types.contains("relay") ? "Relayed media" : "Direct media"
                }
                if feedback.renderedFrames == 0 {
                    emptyIntervals += 1
                    if emptyIntervals == 6 { self.configure(refresh: true) }
                    if emptyIntervals >= 20 {
                        self.fail(message: "The peer connected but no screen frame was displayed."); return
                    }
                }
                self.previousStatistics = current; self.previousStatisticsTime = now
            }
        }
    }

    private func fail(_ error: Error) {
        fail(message: DieterRPCFailure.message(for: error))
    }

    private func fail(message: String) {
        errorMessage = message
        phase = .failed(message)
        disconnect()
    }

    private func rememberSignalingReceiveFailure(_ message: String, generation token: UInt64) {
        guard owns(token) else { return }
        signalingReceiveFailure = message
    }

    private func createOffer(_ peer: RTCPeerConnection, constraints: RTCMediaConstraints) async throws
        -> RTCSessionDescription
    {
        try await awaitCancellableCallback { completion in
            peer.offer(for: constraints) { description, error in
                if let description {
                    completion(.success(description))
                } else {
                    completion(.failure(error ?? CancellationError()))
                }
            }
        }
    }

    private func setLocalDescription(_ description: RTCSessionDescription, on peer: RTCPeerConnection)
        async throws
    {
        try await awaitCancellableCallback { (completion: @escaping @Sendable (Result<Void, Error>) -> Void) in
            peer.setLocalDescription(description) { error in
                if let error { completion(.failure(error)) } else { completion(.success(())) }
            }
        }
    }

    private func setRemoteDescription(
        _ description: RTCSessionDescription, on peer: RTCPeerConnection
    ) async throws {
        try await awaitCancellableCallback { (completion: @escaping @Sendable (Result<Void, Error>) -> Void) in
            peer.setRemoteDescription(description) { error in
                if let error { completion(.failure(error)) } else { completion(.success(())) }
            }
        }
    }

    private func addIceCandidate(_ candidate: RTCIceCandidate) async throws {
        guard let peerConnection else { throw CancellationError() }
        try await awaitCancellableCallback { (completion: @escaping @Sendable (Result<Void, Error>) -> Void) in
            peerConnection.add(candidate) { error in
                if let error { completion(.failure(error)) } else { completion(.success(())) }
            }
        }
    }
}

private final class RemoteDesktopPeerDelegate: NSObject, RTCPeerConnectionDelegate,
    @unchecked Sendable
{
    weak var owner: RemoteDesktopController?

    func peerConnection(
        _ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState
    ) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        guard let track = stream.videoTracks.first else { return }
        Task { @MainActor [weak owner] in
            guard let owner, owner.owns(peer: peerConnection) else { return }
            owner.received(track: track)
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(
        _ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState
    ) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor [weak owner] in
            guard let owner, owner.owns(peer: peerConnection) else { return }
            owner.generated(candidate: candidate)
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    func peerConnection(
        _ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState
    ) {
        Task { @MainActor [weak owner] in
            guard let owner, owner.owns(peer: peerConnection) else { return }
            owner.connectionStateChanged(newState)
        }
    }
    func peerConnection(
        _ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver,
        streams: [RTCMediaStream]
    ) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        Task { @MainActor [weak owner] in
            guard let owner, owner.owns(peer: peerConnection) else { return }
            owner.received(track: track)
        }
    }
}

private final class RemoteDesktopDataChannelDelegate: NSObject, RTCDataChannelDelegate,
    @unchecked Sendable
{
    weak var owner: RemoteDesktopController?

    init(owner: RemoteDesktopController) { self.owner = owner }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Task { @MainActor [weak owner] in
            guard let owner, owner.owns(channel: dataChannel) else { return }
            owner.updateControlReadiness()
            if dataChannel.readyState == .closed { owner.releaseAllInput() }
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard buffer.isBinary, buffer.data.count <= 350_000,
            let event = try? Dieter_V1_RemoteDesktopHostEvent(serializedBytes: buffer.data)
        else { return }
        Task { @MainActor [weak owner] in
            guard let owner, owner.owns(channel: dataChannel) else { return }
            owner.receiveHost(event)
        }
    }
}

// AppKit phase bitmasks differ from the Quartz event fields.
enum RemoteDesktopScrollPhases {
    static func scroll(_ phase: NSEvent.Phase) -> UInt32 {
        var value: UInt32 = 0
        if phase.contains(.began) { value |= 1 }
        if phase.contains(.changed) || phase.contains(.stationary) { value |= 2 }
        if phase.contains(.ended) { value |= 4 }
        if phase.contains(.cancelled) { value |= 8 }
        if phase.contains(.mayBegin) { value |= 128 }
        return value
    }
    static func momentum(_ phase: NSEvent.Phase) -> UInt32 {
        if phase.contains(.ended) || phase.contains(.cancelled) { return 3 }
        if phase.contains(.began) { return 1 }
        if phase.contains(.changed) || phase.contains(.stationary) { return 2 }
        return 0
    }
}
