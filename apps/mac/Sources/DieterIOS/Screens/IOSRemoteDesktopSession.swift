#if os(iOS)
    import DieterAPI
    import DieterClient
    import DieterCore
    import Foundation
    import Observation
    import SwiftProtobuf
    import UIKit
    @preconcurrency import WebRTC

    enum IOSRemoteDesktopPhase: Equatable, Sendable {
        case idle
        case loading
        case disabled(String)
        case connecting
        case waitingForHostApproval
        case streaming
        case reconnecting
        case failed(String)

        var label: String {
            switch self {
            case .idle: "Not connected"
            case .loading: "Checking machine…"
            case .disabled: "Screen sharing is off"
            case .connecting: "Connecting…"
            case .waitingForHostApproval: "Waiting for approval on Linux host…"
            case .streaming: "Live"
            case .reconnecting: "Reconnecting…"
            case .failed: "Connection failed"
            }
        }
    }

    @MainActor
    @Observable
    final class IOSRemoteDesktopSession {
        var phase: IOSRemoteDesktopPhase = .idle
        var capabilities = Dieter_V1_RemoteDesktopCapabilities()
        var settings = Dieter_V1_RemoteDesktopSettings()
        var sessionState = Dieter_V1_RemoteDesktopSessionState()
        var cursor = Dieter_V1_RemoteDesktopCursor()
        var routeLabel = ""
        var machineName = ""
        var errorMessage = ""
        var controlActive = false
        var controlUnavailableReason = ""
        var controlTransferPending = false
        var controlTransferError = ""
        private(set) var preferredMaxFPS = IOSRemoteDesktopFrameRate.maximum
        var quality: Dieter_V1_RemoteDesktopQuality = .auto
        var keyboardModifiers: UInt32 = 0
        var videoSize = CGSize(width: 16, height: 9)

        var availableFrameRates: [Int32] {
            IOSRemoteDesktopFrameRate.available(hostMaximum: capabilities.maxFps)
        }
        var canTransferControl: Bool {
            binding?.inputProtocolVersion == 3 && binding?.controlGranted == true
        }
        @ObservationIgnored private var openConnection:
            (@MainActor () async throws -> RemoteDesktopSignalingConnection)?
        @ObservationIgnored private var connectTask: Task<Void, Never>?
        @ObservationIgnored private var signalingTask: Task<Void, Never>?
        @ObservationIgnored private var leaseTask: Task<Void, Never>?
        @ObservationIgnored private var recoveryTask: Task<Void, Never>?
        @ObservationIgnored private var peerWatchdog: Task<Void, Never>?
        @ObservationIgnored private var viewportTask: Task<Void, Never>?
        @ObservationIgnored private var keyboardHandler: ((Bool) -> Void)?
        @ObservationIgnored private var cursorHandler: ((Dieter_V1_RemoteDesktopCursor) -> Void)?

        private var generation: UInt64 = 0
        private var recoveryAttempts = 0
        private var factory: RTCPeerConnectionFactory?
        private var peerConnection: RTCPeerConnection?
        private let peerDelegate = IOSRemoteDesktopPeerDelegate()
        private var connection: RemoteDesktopSignalingConnection?
        private var request: Dieter_V1_StartRemoteDesktopRequest?
        private var binding: Dieter_V1_RemoteDesktopSessionBinding?
        private var answerSDP: String?
        private var sessionID = ""
        private var remoteDescriptionApplied = false
        private var authorized = false
        private var localCandidates: [RTCIceCandidate] = []
        private var remoteCandidates: [RTCIceCandidate] = []
        private var pointerChannel: RTCDataChannel?
        private var stateChannel: RTCDataChannel?
        private var hostChannel: RTCDataChannel?
        private var pointerDelegate: IOSRemoteDesktopDataChannelDelegate?
        private var stateDelegate: IOSRemoteDesktopDataChannelDelegate?
        private var hostDelegate: IOSRemoteDesktopDataChannelDelegate?
        private var videoTrack: RTCVideoTrack?
        private var videoRelay: IOSRemoteDesktopVideoRelay!
        private var presentedGeneration: UInt64 = 0
        private var pointerSequence: UInt64 = 0
        private var stateSequence: UInt64 = 0
        private var eventOrdinal: UInt64 = 0
        private var lastPointer = CGPoint(x: 0.5, y: 0.5)
        private var desiredConfiguration = Dieter_V1_RemoteDesktopStreamConfiguration()

        init() {
            peerDelegate.owner = self
            videoRelay = IOSRemoteDesktopVideoRelay { [weak self] token in
                Task { @MainActor [weak self] in self?.presentedFrame(token: token) }
            }
        }

        func connect(
            machineName: String,
            open: @escaping @MainActor () async throws -> RemoteDesktopSignalingConnection
        ) {
            disconnect()
            self.machineName = machineName
            openConnection = open
            recoveryAttempts = 0
            beginConnection()
        }

        func disconnect() {
            openConnection = nil
            teardown(nextPhase: .idle)
        }

        func reconnect() {
            guard openConnection != nil else { return }
            recover(immediate: true)
        }

        func enableAndConnect() {
            guard let connection else { return }
            let token = generation
            connectTask?.cancel()
            connectTask = Task { [weak self] in
                guard let self else { return }
                do {
                    self.settings = try await connection.rpc.updateRemoteDesktopSettings(
                        enabled: true, controlEnabled: true)
                    guard self.owns(token) else { return }
                    self.recover(immediate: true)
                } catch {
                    guard self.owns(token) else { return }
                    self.fail(error)
                }
            }
        }

        private func beginConnection() {
            guard connectTask == nil, let openConnection else { return }
            phase = recoveryAttempts == 0 ? .loading : .reconnecting
            errorMessage = ""
            let token = generation
            connectTask = Task { [weak self] in
                guard let self else { return }
                defer { if self.owns(token) { self.connectTask = nil } }
                do {
                    let connection = try await openConnection()
                    guard self.owns(token) else { connection.shutdown(); return }
                    self.connection = connection
                    self.routeLabel = connection.routeLabel
                    self.settings = try await connection.rpc.remoteDesktopSettings()
                    guard self.owns(token) else { return }
                    self.capabilities = try await connection.rpc.remoteDesktopCapabilities()
                    guard self.owns(token) else { return }
                    guard self.settings.enabled else {
                        self.phase = .disabled(self.capabilities.unavailableReason)
                        return
                    }
                    guard self.capabilities.ready else {
                        throw NSError(
                            domain: "DieterScreens", code: 5,
                            userInfo: [
                                NSLocalizedDescriptionKey: self.capabilities.unavailableReason.isEmpty
                                    ? "Screen sharing is not ready on this machine."
                                    : self.capabilities.unavailableReason
                            ])
                    }
                    try await self.startPeer(generation: token)
                } catch {
                    guard self.owns(token) else { return }
                    if DieterRPCFailure.isTransient(error) || DieterRPCFailure.isAuthenticationFailure(error) {
                        self.recover()
                    } else if !DieterRPCFailure.isCancellation(error) {
                        self.fail(error)
                    }
                }
            }
        }

        private func startPeer(generation token: UInt64) async throws {
            guard owns(token), let connection else { throw CancellationError() }
            phase =
                capabilities.platform == "linux" && capabilities.capturePermission == "not_requested"
                ? .waitingForHostApproval : .connecting
            let rtcConfiguration = RTCConfiguration()
            rtcConfiguration.sdpSemantics = .unifiedPlan
            rtcConfiguration.continualGatheringPolicy = .gatherContinually
            rtcConfiguration.iceServers = connection.rtcConfiguration.iceServers.map {
                RTCIceServer(
                    urlStrings: $0.urls,
                    username: $0.username.isEmpty ? nil : $0.username,
                    credential: $0.credential.isEmpty ? nil : $0.credential)
            }
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            let factory = RTCPeerConnectionFactory(
                encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
            self.factory = factory
            guard
                let peer = factory.peerConnection(
                    with: rtcConfiguration, constraints: constraints, delegate: peerDelegate)
            else {
                throw NSError(
                    domain: "DieterScreens", code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "WebRTC could not create a peer connection."])
            }
            peerConnection = peer

            let pointerConfiguration = RTCDataChannelConfiguration()
            pointerConfiguration.isOrdered = false
            pointerConfiguration.maxRetransmits = 0
            let stateConfiguration = RTCDataChannelConfiguration()
            stateConfiguration.isOrdered = true
            pointerChannel = peer.dataChannel(forLabel: "dieter-pointer-v2", configuration: pointerConfiguration)
            stateChannel = peer.dataChannel(forLabel: "dieter-input-state-v2", configuration: stateConfiguration)
            hostChannel = peer.dataChannel(forLabel: "dieter-session-v2", configuration: stateConfiguration)
            pointerDelegate = IOSRemoteDesktopDataChannelDelegate(owner: self, role: .pointer)
            stateDelegate = IOSRemoteDesktopDataChannelDelegate(owner: self, role: .state)
            hostDelegate = IOSRemoteDesktopDataChannelDelegate(owner: self, role: .host)
            pointerChannel?.delegate = pointerDelegate
            stateChannel?.delegate = stateDelegate
            hostChannel?.delegate = hostDelegate

            let inputProtocolVersion: UInt32 =
                capabilities.supportedInputProtocolVersions.contains(3) ? 3 : 2
            let transceiver = RTCRtpTransceiverInit()
            transceiver.direction = .recvOnly
            guard let video = peer.addTransceiver(of: .video, init: transceiver) else {
                throw NSError(
                    domain: "DieterScreens", code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "WebRTC could not create a receive-only video track."])
            }
            let codecs = factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs.filter {
                $0.name.caseInsensitiveCompare("H264") == .orderedSame
                    || $0.name.caseInsensitiveCompare("flexfec-03") == .orderedSame
            }
            guard !codecs.isEmpty else {
                throw NSError(
                    domain: "DieterScreens", code: 12,
                    userInfo: [NSLocalizedDescriptionKey: "This device has no compatible H.264 decoder."])
            }
            try video.setCodecPreferences(codecs, error: ())
            let offer = try await createOffer(peer, constraints: constraints)
            guard owns(token), peerConnection === peer else { throw CancellationError() }
            try await setLocalDescription(offer, on: peer)
            guard owns(token), peerConnection === peer else { throw CancellationError() }

            var request = Dieter_V1_StartRemoteDesktopRequest()
            request.clientNonce = UUID().uuidString.lowercased()
            request.codecPreference = .h264
            request.referenceRecovery = false
            request.inputProtocolVersion = inputProtocolVersion
            request.clientName = "iOS"
            request.rtcConfiguration = connection.rtcConfiguration
            request.displayID =
                capabilities.displays.first(where: { $0.id == desiredConfiguration.displayID })?.id
                ?? capabilities.displays.first(where: \.primary)?.id
                ?? capabilities.displays.first?.id ?? "primary"
            request.maxFps = IOSRemoteDesktopFrameRate.capped(
                preferredMaxFPS, hostMaximum: capabilities.maxFps)
            request.maxBitrateKbps = 12_000
            request.maxWidth = desiredConfiguration.maxWidth > 0 ? desiredConfiguration.maxWidth : 1_920
            request.maxHeight = desiredConfiguration.maxHeight > 0 ? desiredConfiguration.maxHeight : 1_080
            request.quality = quality
            let portalCanRequestControl =
                capabilities.platform == "linux" && capabilities.controlPermission == "not_requested"
            request.control =
                settings.controlEnabled && capabilities.controlSupported
                && (capabilities.controlPermission == "granted" || portalCanRequestControl)
            request.embeddedCursor = !capabilities.cursorSupported
            request.clipboard = false
            controlUnavailableReason =
                settings.controlEnabled && !request.control
                ? (capabilities.platform == "linux"
                    ? "Remote-control permission is required from the Linux desktop portal"
                    : "Accessibility permission is required on the host") : ""
            var description = Dieter_V1_RemoteDesktopSessionDescription()
            description.type = "offer"
            description.sdp = offer.sdp
            request.offer = description
            self.request = request
            desiredConfiguration.displayID = request.displayID
            desiredConfiguration.maxWidth = request.maxWidth
            desiredConfiguration.maxHeight = request.maxHeight
            desiredConfiguration.maxFps = request.maxFps
            desiredConfiguration.maxBitrateKbps = request.maxBitrateKbps
            desiredConfiguration.quality = request.quality
            desiredConfiguration.embeddedCursor = request.embeddedCursor
            startSignaling(connection: connection, request: request)
            startWatchdog(token: token)
        }

        private func startSignaling(
            connection: RemoteDesktopSignalingConnection,
            request: Dieter_V1_StartRemoteDesktopRequest
        ) {
            signalingTask?.cancel()
            let token = generation
            signalingTask = Task { [weak self] in
                do {
                    try await connection.rpc.startRemoteDesktop(request) { [weak self] signal in
                        guard let self else { throw CancellationError() }
                        try await self.receive(signal, generation: token)
                    }
                    guard !Task.isCancelled else { return }
                    throw NSError(
                        domain: "DieterScreens", code: 8,
                        userInfo: [NSLocalizedDescriptionKey: "Screen-sharing signaling ended."])
                } catch {
                    guard let self, self.owns(token) else { return }
                    if DieterRPCFailure.isCancellation(error) { return }
                    if DieterRPCFailure.isTransient(error) || DieterRPCFailure.isAuthenticationFailure(error) {
                        self.recover()
                    } else {
                        self.fail(error)
                    }
                }
            }
        }

        private func startWatchdog(token: UInt64) {
            peerWatchdog?.cancel()
            peerWatchdog = Task { [weak self] in
                try? await DieterTaskSleep.seconds(20)
                guard let self, self.owns(token), self.phase != .streaming else { return }
                if self.capabilities.platform == "linux" {
                    try? await DieterTaskSleep.seconds(150)
                    guard self.owns(token), self.phase != .streaming else { return }
                }
                self.recover()
            }
        }

        private func receive(_ signal: Dieter_V1_RemoteDesktopSignal, generation token: UInt64) async throws {
            guard owns(token), !signal.sessionID.isEmpty else { throw CancellationError() }
            if sessionID.isEmpty {
                sessionID = signal.sessionID
                flushLocalCandidates()
                startLease(token: token)
            } else if signal.sessionID != sessionID {
                throw RemoteDesktopSessionTrust.Failure.invalidBinding
            }
            switch signal.payload {
            case .binding(let value):
                if let binding, binding != value { throw RemoteDesktopSessionTrust.Failure.invalidBinding }
                binding = value
                try await applyVerifiedAnswerIfReady(token: token)
            case .description_p(let value):
                guard value.type == "answer" else { throw RemoteDesktopSessionTrust.Failure.invalidBinding }
                if let answerSDP, answerSDP != value.sdp {
                    throw RemoteDesktopSessionTrust.Failure.invalidBinding
                }
                answerSDP = value.sdp
                try await applyVerifiedAnswerIfReady(token: token)
            case .candidate(let value):
                let candidate = RTCIceCandidate(
                    sdp: value.candidate, sdpMLineIndex: value.sdpMlineIndex,
                    sdpMid: value.sdpMid.isEmpty ? nil : value.sdpMid)
                if remoteDescriptionApplied {
                    try await addIceCandidate(candidate)
                } else {
                    guard remoteCandidates.count < 256 else { throw CancellationError() }
                    remoteCandidates.append(candidate)
                }
            case .state(let value):
                applySessionState(value)
                if value.phase == "closed" {
                    throw NSError(
                        domain: "DieterScreens", code: 9,
                        userInfo: [
                            NSLocalizedDescriptionKey: value.reason.isEmpty
                                ? "The screen-sharing session closed." : value.reason
                        ])
                }
            case .error(let value):
                if value.recoverable {
                    recover()
                    throw CancellationError()
                }
                throw NSError(
                    domain: "DieterScreens", code: 11,
                    userInfo: [NSLocalizedDescriptionKey: value.message])
            case .leaseHeartbeat, .none:
                break
            }
        }

        private func applyVerifiedAnswerIfReady(token: UInt64) async throws {
            guard !remoteDescriptionApplied, let connection, let request, let binding, let answerSDP else { return }
            try RemoteDesktopSessionTrust.verify(
                binding: binding, sessionID: sessionID, clientNonce: request.clientNonce,
                offerSDP: request.offer.sdp, answerSDP: answerSDP,
                daemonCertificatePEM: connection.daemonCertificatePEM)
            guard binding.controlGranted == request.control,
                binding.displayID == request.displayID,
                binding.inputProtocolVersion == request.inputProtocolVersion
            else { throw RemoteDesktopSessionTrust.Failure.invalidBinding }
            guard let peerConnection else { throw CancellationError() }
            try await setRemoteDescription(
                RTCSessionDescription(type: .answer, sdp: answerSDP), on: peerConnection)
            guard owns(token), self.peerConnection === peerConnection else { throw CancellationError() }
            remoteDescriptionApplied = true
            authorized = true
            let candidates = remoteCandidates
            remoteCandidates.removeAll()
            for candidate in candidates { try await addIceCandidate(candidate) }
            updateControlReadiness()
        }

        private func startLease(token: UInt64) {
            leaseTask?.cancel()
            guard let connection, !sessionID.isEmpty else { return }
            let id = sessionID
            leaseTask = Task { [weak self] in
                var heartbeat = Dieter_V1_RemoteDesktopSignal()
                heartbeat.sessionID = id
                heartbeat.leaseHeartbeat = Google_Protobuf_Empty()
                while !Task.isCancelled {
                    do {
                        try await DieterTaskSleep.seconds(5)
                        try Task.checkCancellation()
                        try await connection.rpc.sendRemoteDesktopSignal(heartbeat)
                    } catch {
                        guard let self, self.owns(token), !DieterRPCFailure.isCancellation(error) else { return }
                        if self.peerConnection?.connectionState != .connected { self.recover() }
                        return
                    }
                }
            }
        }

        fileprivate func generated(candidate: RTCIceCandidate) {
            guard !sessionID.isEmpty else {
                if localCandidates.count < 256 { localCandidates.append(candidate) }
                return
            }
            send(candidate: candidate)
        }

        private func flushLocalCandidates() {
            let values = localCandidates
            localCandidates.removeAll()
            values.forEach(send(candidate:))
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
            guard videoTrack?.isEqual(track) != true else { return }
            videoTrack?.remove(videoRelay)
            videoTrack = track
            videoRelay.use(token: generation)
            track.add(videoRelay)
        }

        fileprivate func connectionStateChanged(_ state: RTCPeerConnectionState) {
            switch state {
            case .connected:
                peerWatchdog?.cancel()
                peerWatchdog = nil
                phase = presentedGeneration > 0 ? .streaming : .connecting
            case .disconnected:
                releaseAllInput()
                controlActive = false
                phase = .reconnecting
                let token = generation
                peerWatchdog?.cancel()
                peerWatchdog = Task { [weak self] in
                    try? await DieterTaskSleep.seconds(3)
                    guard let self, self.owns(token), self.peerConnection?.connectionState != .connected else {
                        return
                    }
                    self.recover()
                }
            case .failed, .closed:
                recover()
            default:
                break
            }
        }

        fileprivate func channelChanged(_ channel: RTCDataChannel, role: IOSRemoteDesktopChannelRole) {
            guard owns(channel: channel, role: role) else { return }
            updateControlReadiness()
            if channel.readyState == .closed, role != .pointer { recover() }
        }

        fileprivate func receiveHost(_ event: Dieter_V1_RemoteDesktopHostEvent) {
            guard authorized else { return }
            switch event.payload {
            case .state(let value): applySessionState(value)
            case .cursor(let value):
                guard value.displayGeneration == sessionState.displayGeneration else { return }
                cursor = value
                cursorHandler?(value)
            case .inputAck(let value): sessionState.lastInputOrdinal = value
            case .reference, nil: break
            }
        }

        private func applySessionState(_ received: Dieter_V1_RemoteDesktopSessionState) {
            guard received.displayGeneration >= sessionState.displayGeneration else { return }
            var state = received
            if state.displayGeneration != sessionState.displayGeneration {
                releaseAllInput()
                presentedGeneration = 0
                cursor = .init()
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
            if state.clipboardGeneration < sessionState.clipboardGeneration {
                state.clipboardGeneration = sessionState.clipboardGeneration
                state.clipboardEnabled = sessionState.clipboardEnabled
            }
            sessionState = state
            updateControlReadiness()
        }

        private func presentedFrame(token: UInt64) {
            guard owns(token), authorized, sessionState.displayGeneration > 0 else { return }
            presentedGeneration = sessionState.displayGeneration
            phase = .streaming
            recoveryAttempts = 0
            updateControlReadiness()
        }

        private func updateControlReadiness() {
            controlActive =
                authorized && binding?.controlGranted == true
                && (binding?.inputProtocolVersion != 3 || sessionState.controlActive)
                && pointerChannel?.readyState == .open
                && stateChannel?.readyState == .open && hostChannel?.readyState == .open
                && sessionState.displayGeneration > 0
                && presentedGeneration == sessionState.displayGeneration
        }

        func attach(renderer: any RTCVideoRenderer) {
            videoRelay.attach(renderer)
        }

        func detach(renderer: any RTCVideoRenderer) {
            videoRelay.detach(renderer)
        }

        func videoSizeChanged(_ size: CGSize) {
            guard size.width > 0, size.height > 0 else { return }
            videoSize = size
        }

        func setKeyboardHandler(_ handler: ((Bool) -> Void)?) { keyboardHandler = handler }
        func showKeyboard(_ show: Bool) { keyboardHandler?(show) }
        func setCursorHandler(_ handler: ((Dieter_V1_RemoteDesktopCursor) -> Void)?) {
            cursorHandler = handler
            if let handler { handler(cursor) }
        }

        func pointer(x: CGFloat, y: CGFloat) {
            let point = CGPoint(x: max(0, min(1, x)), y: max(0, min(1, y)))
            lastPointer = point
            guard controlActive else { return }
            var value = Dieter_V1_RemoteDesktopPointerMove()
            value.normalizedX = normalized(point.x)
            value.normalizedY = normalized(point.y)
            sendPointer(.pointerMove(value))
        }

        func button(
            _ button: Dieter_V1_RemoteDesktopPointerButton.Button,
            down: Bool,
            x: CGFloat? = nil,
            y: CGFloat? = nil,
            clickCount: Int = 1
        ) {
            if let x, let y { lastPointer = CGPoint(x: max(0, min(1, x)), y: max(0, min(1, y))) }
            var value = Dieter_V1_RemoteDesktopPointerButton()
            value.button = button
            value.down = down
            value.clickCount = Int32(max(0, min(3, clickCount)))
            value.normalizedX = normalized(lastPointer.x)
            value.normalizedY = normalized(lastPointer.y)
            value.modifiers = keyboardModifiers
            sendState(.pointerButton(value))
        }

        func click(_ button: Dieter_V1_RemoteDesktopPointerButton.Button = .left) {
            self.button(button, down: true)
            self.button(button, down: false)
        }

        func scroll(deltaX: CGFloat, deltaY: CGFloat, phase: UInt32) {
            var value = Dieter_V1_RemoteDesktopScroll()
            value.deltaX = Int32(clamping: Int(deltaX.rounded()))
            value.deltaY = Int32(clamping: Int(deltaY.rounded()))
            value.precise = true
            value.preciseDeltaX = deltaX
            value.preciseDeltaY = deltaY
            value.phase = phase
            value.modifiers = keyboardModifiers
            sendState(.scroll(value))
        }

        func text(_ text: String) {
            guard !text.isEmpty, text.utf8.count <= 8_192 else { return }
            var chunk = ""
            for character in text {
                let value = String(character)
                if chunk.utf8.count + value.utf8.count > 2_048 {
                    sendTextChunk(chunk)
                    chunk = ""
                }
                chunk.append(character)
            }
            sendTextChunk(chunk)
        }

        private func sendTextChunk(_ text: String) {
            guard !text.isEmpty else { return }
            var value = Dieter_V1_RemoteDesktopText()
            value.text = text
            sendState(.text(value))
        }

        func key(hid: UInt32, down: Bool, repeat isRepeat: Bool = false) {
            var value = Dieter_V1_RemoteDesktopKey()
            value.physicalKey = min(255, hid)
            value.down = down
            value.repeat = isRepeat
            value.modifiers = keyboardModifiers
            sendState(.key(value))
        }

        func press(hid: UInt32) {
            key(hid: hid, down: true)
            key(hid: hid, down: false)
        }

        func releaseAllInput() {
            guard controlActive else { return }
            sendState(.releaseAll(Dieter_V1_RemoteDesktopReleaseAll()), failOnError: false)
        }

        private func sendPointer(_ payload: Dieter_V1_RemoteDesktopInput.OneOf_Payload) {
            guard controlActive, let channel = pointerChannel, channel.readyState == .open,
                channel.bufferedAmount < 65_536, let binding
            else { return }
            pointerSequence &+= 1
            send(payload, sequence: pointerSequence, binding: binding, channel: channel)
        }

        private func sendState(
            _ payload: Dieter_V1_RemoteDesktopInput.OneOf_Payload,
            failOnError: Bool = true
        ) {
            guard controlActive, let channel = stateChannel, channel.readyState == .open,
                channel.bufferedAmount < 65_536, let binding
            else { return }
            stateSequence &+= 1
            send(
                payload, sequence: stateSequence, binding: binding, channel: channel,
                failOnError: failOnError)
        }

        private func send(
            _ payload: Dieter_V1_RemoteDesktopInput.OneOf_Payload,
            sequence: UInt64,
            binding: Dieter_V1_RemoteDesktopSessionBinding,
            channel: RTCDataChannel,
            failOnError: Bool = true
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
            if !channel.sendData(RTCDataBuffer(data: data, isBinary: true)), failOnError {
                controlActive = false
                recover()
            }
        }

        private func normalized(_ value: CGFloat) -> Int32 {
            Int32((max(0, min(1, value)) * 1_000_000).rounded())
        }

        func transferControl(take: Bool) {
            guard canTransferControl, !controlTransferPending, let connection else { return }
            releaseAllInput()
            controlTransferPending = true
            controlTransferError = ""
            let token = generation
            Task { [weak self] in
                guard let self else { return }
                do {
                    let value = try await connection.rpc.setRemoteDesktopControl(
                        sessionID: self.sessionID, take: take)
                    if self.owns(token) { self.applySessionState(value) }
                } catch {
                    if self.owns(token) { self.controlTransferError = IOSUserError.message(error) }
                }
                if self.owns(token) { self.controlTransferPending = false }
            }
        }

        func configure(
            displayID: String? = nil,
            quality: Dieter_V1_RemoteDesktopQuality? = nil,
            maxFPS: Int32? = nil,
            refresh: Bool = false
        ) {
            guard let connection, !sessionID.isEmpty else { return }
            releaseAllInput()
            if let displayID { desiredConfiguration.displayID = displayID }
            if let quality { desiredConfiguration.quality = quality; self.quality = quality }
            if let maxFPS {
                preferredMaxFPS = IOSRemoteDesktopFrameRate.capped(
                    maxFPS, hostMaximum: capabilities.maxFps)
                desiredConfiguration.maxFps = preferredMaxFPS
            }
            var request = Dieter_V1_UpdateRemoteDesktopSessionRequest()
            request.sessionID = sessionID
            request.configuration = desiredConfiguration
            request.refresh = refresh
            let token = generation
            Task { [weak self] in
                guard let self else { return }
                do {
                    let value = try await connection.rpc.updateRemoteDesktopSession(request)
                    if self.owns(token) { self.applySessionState(value) }
                } catch {
                    if self.owns(token) { self.fail(error) }
                }
            }
        }

        func setViewport(_ size: CGSize, scale: CGFloat) {
            guard size.width > 0, size.height > 0 else { return }
            let width = Int32(max(640, min(1_920, ceil(size.width * scale / 160) * 160)))
            let height = Int32(max(360, min(1_080, ceil(size.height * scale / 90) * 90)))
            guard desiredConfiguration.maxWidth != width || desiredConfiguration.maxHeight != height else { return }
            desiredConfiguration.maxWidth = width
            desiredConfiguration.maxHeight = height
            viewportTask?.cancel()
            let token = generation
            viewportTask = Task { [weak self] in
                try? await DieterTaskSleep.seconds(0.35)
                guard let self, self.owns(token), !self.sessionID.isEmpty else { return }
                self.configure()
            }
        }

        private func recover(immediate: Bool = false) {
            guard openConnection != nil else { return }
            let delay = immediate ? 0 : min(5, 0.25 * Double(1 << min(recoveryAttempts, 5)))
            recoveryAttempts = min(recoveryAttempts + 1, 6)
            teardown(keepConnectionFactory: true, nextPhase: .reconnecting)
            let token = generation
            recoveryTask = Task { [weak self] in
                try? await DieterTaskSleep.seconds(delay)
                guard let self, self.owns(token), self.openConnection != nil else { return }
                self.recoveryTask = nil
                self.beginConnection()
            }
        }

        private func fail(_ error: Error) {
            fail(message: IOSUserError.message(error))
        }

        private func fail(message: String) {
            errorMessage = message
            openConnection = nil
            teardown(nextPhase: .failed(message))
        }

        private func teardown(
            keepConnectionFactory: Bool = false,
            nextPhase: IOSRemoteDesktopPhase
        ) {
            generation &+= 1
            connectTask?.cancel(); connectTask = nil
            signalingTask?.cancel(); signalingTask = nil
            leaseTask?.cancel(); leaseTask = nil
            recoveryTask?.cancel(); recoveryTask = nil
            peerWatchdog?.cancel(); peerWatchdog = nil
            viewportTask?.cancel(); viewportTask = nil
            releaseAllInput()
            let previousConnection = connection
            let previousSessionID = sessionID
            videoTrack?.remove(videoRelay)
            videoTrack = nil
            videoRelay.use(token: generation)
            pointerChannel?.close(); stateChannel?.close(); hostChannel?.close()
            pointerChannel = nil; stateChannel = nil; hostChannel = nil
            pointerDelegate = nil; stateDelegate = nil; hostDelegate = nil
            peerConnection?.close(); peerConnection = nil
            factory = nil
            connection = nil
            request = nil; binding = nil; answerSDP = nil
            sessionID = ""; remoteDescriptionApplied = false; authorized = false
            localCandidates.removeAll(); remoteCandidates.removeAll()
            presentedGeneration = 0; pointerSequence = 0; stateSequence = 0; eventOrdinal = 0
            sessionState = .init(); cursor = .init(); controlActive = false
            controlTransferPending = false; controlTransferError = ""
            routeLabel = ""
            cursorHandler?(cursor)
            if !keepConnectionFactory { openConnection = nil }
            phase = nextPhase
            if let previousConnection {
                Task {
                    if !previousSessionID.isEmpty {
                        try? await previousConnection.rpc.closeRemoteDesktop(sessionID: previousSessionID)
                    }
                    previousConnection.shutdown()
                }
            }
        }

        private func owns(_ token: UInt64) -> Bool {
            generation == token && !Task.isCancelled
        }

        fileprivate func owns(channel: RTCDataChannel, role: IOSRemoteDesktopChannelRole) -> Bool {
            switch role {
            case .pointer: pointerChannel === channel
            case .state: stateChannel === channel
            case .host: hostChannel === channel
            }
        }

        fileprivate func owns(peer: RTCPeerConnection) -> Bool { peerConnection === peer }

        private func createOffer(
            _ peer: RTCPeerConnection,
            constraints: RTCMediaConstraints
        ) async throws -> RTCSessionDescription {
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

        private func setLocalDescription(
            _ description: RTCSessionDescription,
            on peer: RTCPeerConnection
        ) async throws {
            try await awaitCancellableCallback { (completion: @escaping @Sendable (Result<Void, Error>) -> Void) in
                peer.setLocalDescription(description) { error in
                    if let error { completion(.failure(error)) } else { completion(.success(())) }
                }
            }
        }

        private func setRemoteDescription(
            _ description: RTCSessionDescription,
            on peer: RTCPeerConnection
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

    fileprivate enum IOSRemoteDesktopChannelRole: Sendable { case pointer, state, host }

    private final class IOSRemoteDesktopPeerDelegate: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
        weak var owner: IOSRemoteDesktopSession?

        func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
            guard let track = stream.videoTracks.first else { return }
            Task { @MainActor [weak owner] in
                guard let owner, owner.owns(peer: peerConnection) else { return }
                owner.received(track: track)
            }
        }
        func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
        func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
            Task { @MainActor [weak owner] in
                guard let owner, owner.owns(peer: peerConnection) else { return }
                owner.generated(candidate: candidate)
            }
        }
        func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
            Task { @MainActor [weak owner] in
                guard let owner, owner.owns(peer: peerConnection) else { return }
                owner.connectionStateChanged(newState)
            }
        }
        func peerConnection(
            _ peerConnection: RTCPeerConnection,
            didAdd rtpReceiver: RTCRtpReceiver,
            streams: [RTCMediaStream]
        ) {
            guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
            Task { @MainActor [weak owner] in
                guard let owner, owner.owns(peer: peerConnection) else { return }
                owner.received(track: track)
            }
        }
    }

    private final class IOSRemoteDesktopDataChannelDelegate: NSObject, RTCDataChannelDelegate, @unchecked Sendable {
        weak var owner: IOSRemoteDesktopSession?
        let role: IOSRemoteDesktopChannelRole

        init(owner: IOSRemoteDesktopSession, role: IOSRemoteDesktopChannelRole) {
            self.owner = owner
            self.role = role
        }

        func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
            Task { @MainActor [weak owner] in owner?.channelChanged(dataChannel, role: self.role) }
        }

        func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
            guard role == .host, buffer.isBinary, buffer.data.count <= 350_000,
                let event = try? Dieter_V1_RemoteDesktopHostEvent(serializedBytes: buffer.data)
            else { return }
            Task { @MainActor [weak owner] in
                guard let owner, owner.owns(channel: dataChannel, role: self.role) else { return }
                owner.receiveHost(event)
            }
        }
    }

    private final class IOSRemoteDesktopVideoRelay: NSObject, RTCVideoRenderer, @unchecked Sendable {
        private let lock = NSLock()
        private weak var renderer: (any RTCVideoRenderer)?
        private var size = CGSize.zero
        private var token: UInt64 = 0
        private let onFrame: @Sendable (UInt64) -> Void

        init(onFrame: @escaping @Sendable (UInt64) -> Void) { self.onFrame = onFrame }

        func use(token: UInt64) { lock.withLock { self.token = token } }

        func attach(_ renderer: any RTCVideoRenderer) {
            let size = lock.withLock {
                self.renderer = renderer
                return self.size
            }
            if size.width > 0, size.height > 0 { renderer.setSize(size) }
        }

        func detach(_ renderer: any RTCVideoRenderer) {
            let current = lock.withLock { self.renderer }
            if (current as AnyObject?) === (renderer as AnyObject) {
                lock.withLock { self.renderer = nil }
                renderer.renderFrame(nil)
            }
        }

        func setSize(_ size: CGSize) {
            let renderer = lock.withLock {
                self.size = size
                return self.renderer
            }
            renderer?.setSize(size)
        }

        func renderFrame(_ frame: RTCVideoFrame?) {
            let frame = frame.map { frame in
                let renderTimestamp = IOSRemoteDesktopFrameTimestamp.nanoseconds(
                    decodedNanoseconds: frame.timeStampNs,
                    rtpTimestamp: frame.timeStamp)
                guard renderTimestamp != frame.timeStampNs else { return frame }
                let normalized = RTCVideoFrame(
                    buffer: frame.buffer,
                    rotation: frame.rotation,
                    timeStampNs: renderTimestamp)
                normalized.timeStamp = frame.timeStamp
                return normalized
            }
            let (renderer, token) = lock.withLock { (self.renderer, self.token) }
            renderer?.renderFrame(frame)
            if frame != nil, renderer != nil { onFrame(token) }
        }
    }
#endif

enum IOSRemoteDesktopFrameTimestamp {
    private static let rtpClockRate: UInt64 = 90_000
    private static let nanosecondsPerSecond: UInt64 = 1_000_000_000

    static func nanoseconds(decodedNanoseconds: Int64, rtpTimestamp: Int32) -> Int64 {
        guard decodedNanoseconds == 0 else { return decodedNanoseconds }
        // WebRTC's stock iOS renderers use timeStampNs to reject duplicate frames.
        // Remote desktop frames can carry only their 90 kHz RTP timestamp, leaving
        // timeStampNs at its zero sentinel and causing every frame to be skipped.
        let ticks = UInt64(UInt32(bitPattern: rtpTimestamp)) + 1
        return Int64(ticks * nanosecondsPerSecond / rtpClockRate)
    }
}

enum IOSRemoteDesktopFrameRate {
    static let maximum: Int32 = 30

    static func available(hostMaximum: Int32) -> [Int32] {
        [maximum].filter { $0 <= effectiveHostMaximum(hostMaximum) }
    }

    static func capped(_ requested: Int32, hostMaximum: Int32) -> Int32 {
        max(1, min(requested, maximum, effectiveHostMaximum(hostMaximum)))
    }

    private static func effectiveHostMaximum(_ hostMaximum: Int32) -> Int32 {
        hostMaximum > 0 ? hostMaximum : maximum
    }
}
