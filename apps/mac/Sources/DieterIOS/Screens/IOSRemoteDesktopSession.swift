#if os(iOS)
    import DieterAPI
    import DieterCore
    import DieterShared
    import Foundation
    import Observation
    import SharedCore
    import UIKit
    @preconcurrency import WebRTC

    enum IOSRemoteDesktopPhase: Equatable, Sendable {
        case idle
        case loading
        case permissionRequired(String)
        case unsupported(String)
        case connecting
        case waitingForHostApproval
        case streaming
        case reconnecting
        case failed(String)

        var label: String {
            switch self {
            case .idle: "Not connected"
            case .loading: "Checking machine…"
            case .permissionRequired: "Permission required"
            case .unsupported: "Screen sharing unavailable"
            case .connecting: "Connecting…"
            case .waitingForHostApproval: "Waiting for approval on Linux host…"
            case .streaming: "Live"
            case .reconnecting: "Reconnecting…"
            case .failed: "Connection failed"
            }
        }
    }

    /// SwiftUI adapter for the shared ScreenSession. Swift owns WebRTC and the
    /// renderer; Kotlin owns signaling, identity, recovery, stream policy,
    /// input encoding, control transfer, and session lifetime.
    @MainActor
    @Observable
    final class IOSRemoteDesktopSession {
        var phase: IOSRemoteDesktopPhase = .idle
        var capabilities = Dieter_V1_RemoteDesktopCapabilities()
        var sessionState = Dieter_V1_RemoteDesktopSessionState()
        var cursor = Dieter_V1_RemoteDesktopCursor()
        var routeLabel = ""
        var machineName = ""
        var errorMessage = ""
        var controlActive = false
        var controlUnavailableReason = ""
        var controlTransferPending = false
        var controlTransferError = ""
        private(set) var preferredMaxFPS: Int32 = 30
        var quality: Dieter_V1_RemoteDesktopQuality = .auto
        var keyboardModifiers: UInt32 = 0
        private(set) var keyboardVisible = false
        var videoSize = CGSize(width: 16, height: 9)
        private(set) var availableFrameRates: [Int32] = []
        private(set) var canTransferControl = false

        @ObservationIgnored private let media: IOSScreenMedia
        @ObservationIgnored private let core: LiveCoreClient
        @ObservationIgnored private let scope = "ios-screen-\(UUID().uuidString)"
        @ObservationIgnored private var subscription: SliceSubscription?
        @ObservationIgnored private var queued: Task<Void, Never>?
        @ObservationIgnored private var keyboardHandler: ((Bool) -> Void)?
        @ObservationIgnored private var cursorHandler: ((Dieter_V1_RemoteDesktopCursor) -> Void)?
        @ObservationIgnored private var displayID = ""

        init(store: IOSStore) {
            media = store.screenMedia
            core = store.coreClient
            subscription = SliceSubscription(client: core, slice: .screen, scope: scope) { [weak self] update in
                guard let self else { return }
                switch update.value {
                case .screen(let slice): self.apply(slice)
                case .failure(let failure):
                    self.phase = .failed(failure.message)
                    self.errorMessage = failure.message
                default: break
                }
            }
        }

        isolated deinit {
            subscription?.close()
            media.detach(scope: scope)
        }

        func connect(machineName: String, daemonID: String) {
            self.machineName = machineName
            send { $0.connect = .with { $0.daemonID = daemonID } }
        }

        #if DEBUG
            func connectTestFixture(
                machineName: String, url: String, token: String,
                certificatePEM: Data, rtc: Data
            ) {
                self.machineName = machineName
                send { $0.connect = .with { $0.daemonID = "fixture" } }
            }
        #endif

        func disconnect() { send { $0.disconnect = ClientScreenStep() } }
        func reconnect() { send { $0.resume = ClientScreenStep() } }
        func suspend() {
            send { $0.focused = .with { $0.on = false } }
            send { $0.sleep = ClientScreenStep() }
        }

        fileprivate func apply(_ value: ClientScreenSlice) {
            phase =
                switch value.phase {
                case "loading": .loading
                case "permission_required": .permissionRequired(value.problem)
                case "unsupported": .unsupported(value.problem)
                case "connecting": .connecting
                case "waiting_for_host_approval": .waitingForHostApproval
                case "streaming": .streaming
                case "reconnecting": .reconnecting
                case "failed": .failed(value.problem)
                default: .idle
                }
            capabilities = value.capabilities
            sessionState = value.state
            routeLabel = value.routeLabel
            errorMessage = value.problem
            controlActive = value.controlActive
            canTransferControl = value.canTransferControl
            controlUnavailableReason =
                value.capabilities.platform == "linux"
                ? "Remote-control permission is required from the Linux desktop portal"
                : "Accessibility permission is required on the host"
            controlTransferPending = value.controlTransferring
            controlTransferError = value.controlError
            preferredMaxFPS = value.preferences.maxFps
            quality = value.preferences.quality
            displayID = value.preferences.displayID
            let ceiling = value.capabilities.maxFps > 0 ? value.capabilities.maxFps : 30
            availableFrameRates = [30, 60, 90, 120].filter { $0 <= ceiling }

            var cursor = Dieter_V1_RemoteDesktopCursor()
            cursor.shapeID = String(value.cursorImage.hashValue)
            cursor.png = value.cursorImage
            cursor.hotspotX = value.cursorHotspotX
            cursor.hotspotY = value.cursorHotspotY
            cursor.width = value.cursorWidth
            cursor.height = value.cursorHeight
            cursor.normalizedX = Int32((value.cursorX * 1_000_000).rounded())
            cursor.normalizedY = Int32((value.cursorY * 1_000_000).rounded())
            cursor.visible = value.cursorVisible
            cursor.displayGeneration = value.state.displayGeneration
            self.cursor = cursor
            cursorHandler?(cursor)
        }

        func attach(renderer: any RTCVideoRenderer) { media.attach(scope: scope, renderer: renderer) }
        func detach(renderer: any RTCVideoRenderer) { media.detach(scope: scope, renderer: renderer) }
        func videoSizeChanged(_ size: CGSize) {
            videoSize = size
            media.setSize(scope: scope, size: size)
        }

        func setKeyboardHandler(_ handler: ((Bool) -> Void)?) { keyboardHandler = handler }
        func showKeyboard(_ show: Bool) {
            guard controlActive || !show else { return }
            keyboardVisible = show
            keyboardHandler?(show)
        }
        func keyboardVisibilityChanged(_ visible: Bool) { keyboardVisible = visible }
        func setCursorHandler(_ handler: ((Dieter_V1_RemoteDesktopCursor) -> Void)?) {
            cursorHandler = handler
            handler?(cursor)
        }

        func pointer(x: CGFloat, y: CGFloat) {
            send {
                $0.pointer = .with {
                    $0.x = x; $0.y = y
                }
            }
        }
        func button(
            _ button: Dieter_V1_RemoteDesktopPointerButton.Button,
            down: Bool,
            clicks: UInt32,
            x: CGFloat,
            y: CGFloat
        ) {
            send {
                $0.button = .with {
                    $0.button = button; $0.down = down; $0.clicks = Int32(clicks)
                    $0.x = x; $0.y = y; $0.modifiers = Int32(bitPattern: self.keyboardModifiers)
                }
            }
        }
        func scroll(deltaX: CGFloat, deltaY: CGFloat, phase: UInt32) {
            send {
                $0.scroll = .with {
                    $0.dx = deltaX; $0.dy = deltaY; $0.phase = Int32(bitPattern: phase)
                    $0.modifiers = Int32(bitPattern: self.keyboardModifiers)
                }
            }
        }
        func text(_ text: String) {
            send {
                $0.text = .with {
                    $0.text = text; $0.modifiers = Int32(bitPattern: self.keyboardModifiers)
                }
            }
            keyboardModifiers = 0
        }
        func hardwareKey(hid: UInt32, down: Bool, repeat isRepeat: Bool = false, modifiers: UInt32) {
            send {
                $0.key = .with {
                    $0.hid = Int32(bitPattern: hid); $0.down = down; $0.repeat = isRepeat
                    $0.modifiers = Int32(bitPattern: modifiers | self.keyboardModifiers)
                }
            }
            if !down, !(224...231).contains(hid) { keyboardModifiers = 0 }
        }
        func press(hid: UInt32) {
            hardwareKey(hid: hid, down: true, modifiers: keyboardModifiers)
            hardwareKey(hid: hid, down: false, modifiers: keyboardModifiers)
        }
        func releaseAllInput() {
            send { $0.releaseInput = ClientScreenStep() }
            keyboardModifiers = 0
        }
        func transferControl(take: Bool) { send { $0.control = .with { $0.on = take } } }
        func configure(
            displayID: String? = nil,
            quality: Dieter_V1_RemoteDesktopQuality? = nil,
            maxFPS: Int32? = nil,
            refresh: Bool = false
        ) {
            if let displayID { self.displayID = displayID }
            if let quality { self.quality = quality }
            if let maxFPS { preferredMaxFPS = maxFPS }
            if displayID != nil || quality != nil || maxFPS != nil {
                send {
                    $0.preferences = .with {
                        $0.displayID = self.displayID; $0.quality = self.quality
                        $0.maxFps = self.preferredMaxFPS; $0.clipboard = true
                    }
                }
            }
            if refresh { send { $0.refresh = ClientScreenStep() } }
        }
        func setViewport(_ size: CGSize, scale: CGFloat) {
            send {
                $0.viewport = .with {
                    $0.widthPoints = size.width; $0.heightPoints = size.height; $0.scale = scale
                }
            }
        }

        private func send(_ build: @escaping (inout ClientScreenCommand) -> Void) {
            var screen = ClientScreenCommand()
            screen.scope = scope
            build(&screen)
            let command = ClientCommand.with { $0.screen = screen }
            let previous = queued
            let core = core
            queued = Task {
                await previous?.value
                _ = try? await core.dispatch(command)
            }
        }
    }

    final class IOSScreenMedia: NSObject, NativeScreenMedia, @unchecked Sendable {
        private let lock = NSLock()
        private var relays: [String: IOSRemoteDesktopVideoRelay] = [:]
        private let codecs: [RTCRtpCodecCapability]

        override init() {
            let factory = RTCPeerConnectionFactory(
                encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
            codecs = factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs.filter {
                $0.name.caseInsensitiveCompare("H264") == .orderedSame
                    || $0.name.caseInsensitiveCompare("flexfec-03") == .orderedSame
            }
            super.init()
        }

        func capabilities() -> Data {
            var value = ClientScreenMediaCapabilities()
            value.receiveCodecs = codecs.map { codec in
                .with {
                    $0.name = codec.name
                    $0.profile = codec.parameters["profile-level-id"] ?? ""
                }
            }
            value.initializationFailure =
                codecs.contains(where: { $0.name.caseInsensitiveCompare("H264") == .orderedSame })
                ? "" : "This device has no compatible H.264 decoder."
            return (try? value.serializedData()) ?? Data()
        }

        func create(
            configuration: Data, scope: String,
            events: NativeScreenMediaEvents
        ) -> any NativeScreenMediaEngine {
            let relay = relay(scope: scope)
            relay.setEvents(events)
            do {
                return try IOSScreenMediaEngine(
                    configuration: ClientScreenMediaConfig(serializedBytes: configuration),
                    events: events, relay: relay)
            } catch {
                events.failure(message: error.localizedDescription)
                return IOSFailedScreenMediaEngine(error: error)
            }
        }

        func attach(scope: String, renderer: any RTCVideoRenderer) {
            relay(scope: scope).attach(renderer)
        }

        func detach(scope: String, renderer: any RTCVideoRenderer) {
            relay(scope: scope).detach(renderer)
        }

        func detach(scope: String) {
            lock.withLock { relays.removeValue(forKey: scope) }?.reset()
        }

        func setSize(scope: String, size: CGSize) { relay(scope: scope).setSize(size) }

        private func relay(scope: String) -> IOSRemoteDesktopVideoRelay {
            lock.withLock {
                if let relay = relays[scope] { return relay }
                let relay = IOSRemoteDesktopVideoRelay()
                relays[scope] = relay
                return relay
            }
        }
    }

    final class IOSScreenFixture: NSObject, NativeScreenFixture, @unchecked Sendable {
        private struct Payload: Decodable {
            let url: String
            let certificate: Data
            let rtc: Data
            let token: String
        }

        private let route: NativeScreenFixtureRoute

        private init(_ payload: Payload) {
            route = NativeScreenFixtureRoute(
                url: payload.url, token: payload.token,
                certificatePem: String(data: payload.certificate, encoding: .utf8) ?? "",
                rtc: payload.rtc, label: "Fixture loopback")
        }

        static func fromEnvironment() -> IOSScreenFixture? {
            #if DEBUG
                guard
                    let encoded = ProcessInfo.processInfo.environment["DIETER_IOS_SCREEN_FIXTURE"],
                    let data = Data(base64Encoded: encoded),
                    let payload = try? JSONDecoder().decode(Payload.self, from: data)
                else { return nil }
                return IOSScreenFixture(payload)
            #else
                return nil
            #endif
        }

        func open() -> NativeScreenFixtureRoute? { route }
    }

    private final class IOSFailedScreenMediaEngine: NSObject, NativeScreenMediaEngine {
        let error: Error
        init(error: Error) { self.error = error }
        func createOffer(completion: any NativeScreenTextCompletion) {
            completion.completed(text: nil, error: error.localizedDescription)
        }
        func applyAnswer(sdp: String, completion: any NativeScreenDoneCompletion) {
            completion.completed(error: error.localizedDescription)
        }
        func addRemoteCandidate(candidate: Data, completion: any NativeScreenDoneCompletion) {
            completion.completed(error: error.localizedDescription)
        }
        func send(label: String, bytes: Data) -> Bool { false }
        func isOpen(label: String) -> Bool { false }
        func bufferedAmount(label: String) -> Int64 { 0 }
        func statistics(completion: any NativeScreenSampleCompletion) { completion.completed(sample: nil) }
        func updateFrameGate(
            token: Int64, displayGeneration: Int64, mediaGeneration: Int64,
            mediaTimestamp: Int64
        ) {}
        func resetVideo() {}
        func close() {}
    }

    private final class IOSScreenMediaEngine: NSObject, NativeScreenMediaEngine, @unchecked Sendable {
        private let events: NativeScreenMediaEvents
        private let relay: IOSRemoteDesktopVideoRelay
        private let factory: RTCPeerConnectionFactory
        private let peer: RTCPeerConnection
        private var channels: [String: RTCDataChannel] = [:]
        private var channelLabels: [ObjectIdentifier: String] = [:]
        private var videoTrack: RTCVideoTrack?
        private var closed = false
        init(
            configuration: ClientScreenMediaConfig,
            events: NativeScreenMediaEvents,
            relay: IOSRemoteDesktopVideoRelay
        ) throws {
            self.events = events
            self.relay = relay
            factory = RTCPeerConnectionFactory(
                encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
            let rtcConfiguration = RTCConfiguration()
            rtcConfiguration.sdpSemantics = .unifiedPlan
            rtcConfiguration.continualGatheringPolicy = .gatherContinually
            rtcConfiguration.iceServers = configuration.rtc.iceServers.map {
                RTCIceServer(
                    urlStrings: $0.urls,
                    username: $0.username.isEmpty ? nil : $0.username,
                    credential: $0.credential.isEmpty ? nil : $0.credential)
            }
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            guard
                let peer = factory.peerConnection(
                    with: rtcConfiguration, constraints: constraints, delegate: nil)
            else { throw IOSScreenMediaError.peerCreation }
            self.peer = peer
            super.init()
            peer.delegate = self

            for spec in configuration.channels {
                let config = RTCDataChannelConfiguration()
                config.isOrdered = spec.ordered
                if spec.hasMaxRetransmits { config.maxRetransmits = spec.maxRetransmits }
                guard let channel = peer.dataChannel(forLabel: spec.label, configuration: config) else {
                    throw IOSScreenMediaError.channelCreation(spec.label)
                }
                channel.delegate = self
                channels[channel.label] = channel
                self.channelLabels[ObjectIdentifier(channel)] = channel.label
            }

            let transceiver = RTCRtpTransceiverInit()
            transceiver.direction = .recvOnly
            guard let video = peer.addTransceiver(of: .video, init: transceiver) else {
                throw IOSScreenMediaError.transceiverCreation
            }
            let available = factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs
            let selected = available.compactMap { capability -> (Int, RTCRtpCodecCapability)? in
                let rank = configuration.codecs.indices.first { index in
                    configuration.codecs[index].name.caseInsensitiveCompare(capability.name) == .orderedSame
                        && (configuration.codecs[index].profile.isEmpty
                            || configuration.codecs[index].profile == capability.parameters["profile-level-id"])
                }
                return rank.map { ($0, capability) }
            }.sorted { $0.0 < $1.0 }.map(\.1)
            guard !selected.isEmpty else { throw IOSScreenMediaError.codecUnavailable }
            try video.setCodecPreferences(selected, error: ())
        }

        private func offer() async throws -> String {
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            let offer: RTCSessionDescription = try await awaitCancellableCallback { completion in
                self.peer.offer(for: constraints) { description, error in
                    if let description {
                        completion(.success(description))
                    } else {
                        completion(.failure(error ?? CancellationError()))
                    }
                }
            }
            try await setDescription(offer, local: true)
            return offer.sdp
        }

        private func answer(_ sdp: String) async throws {
            try await setDescription(RTCSessionDescription(type: .answer, sdp: sdp), local: false)
        }

        private func addCandidate(_ candidate: Data) async throws {
            let value = try Dieter_V1_RemoteDesktopICECandidate(serializedBytes: candidate)
            let ice = RTCIceCandidate(
                sdp: value.candidate, sdpMLineIndex: value.sdpMlineIndex,
                sdpMid: value.sdpMid.isEmpty ? nil : value.sdpMid)
            try await awaitCancellableCallback { (completion: @escaping @Sendable (Result<Void, Error>) -> Void) in
                self.peer.add(ice) { error in
                    if let error { completion(.failure(error)) } else { completion(.success(())) }
                }
            }
        }

        private func setDescription(_ description: RTCSessionDescription, local: Bool) async throws {
            try await awaitCancellableCallback { (completion: @escaping @Sendable (Result<Void, Error>) -> Void) in
                let callback: @Sendable (Error?) -> Void = { error in
                    if let error { completion(.failure(error)) } else { completion(.success(())) }
                }
                if local {
                    self.peer.setLocalDescription(description, completionHandler: callback)
                } else {
                    self.peer.setRemoteDescription(description, completionHandler: callback)
                }
            }
        }

        func createOffer(completion: any NativeScreenTextCompletion) {
            let completion = NativeCallback(completion)
            Task {
                do { completion.value.completed(text: try await offer(), error: nil) } catch {
                    completion.value.completed(text: nil, error: error.localizedDescription)
                }
            }
        }

        func applyAnswer(sdp: String, completion: any NativeScreenDoneCompletion) {
            let completion = NativeCallback(completion)
            Task {
                do { try await answer(sdp); completion.value.completed(error: nil) } catch {
                    completion.value.completed(error: error.localizedDescription)
                }
            }
        }

        func addRemoteCandidate(candidate: Data, completion: any NativeScreenDoneCompletion) {
            let completion = NativeCallback(completion)
            Task {
                do { try await addCandidate(candidate); completion.value.completed(error: nil) } catch {
                    completion.value.completed(error: error.localizedDescription)
                }
            }
        }

        func send(label: String, bytes: Data) -> Bool {
            guard !closed, let channel = channels[label], channel.readyState == .open else { return false }
            return channel.sendData(RTCDataBuffer(data: bytes, isBinary: true))
        }
        func isOpen(label: String) -> Bool { !closed && channels[label]?.readyState == .open }
        func bufferedAmount(label: String) -> Int64 { Int64(channels[label]?.bufferedAmount ?? 0) }
        func statistics(completion: any NativeScreenSampleCompletion) {
            let completion = NativeCallback(completion)
            Task { completion.value.completed(sample: await receiverSample()) }
        }

        private func receiverSample() async -> NativeReceiverSample? {
            guard !closed else { return nil }
            let report = await peer.statistics()
            guard !closed else { return nil }
            var inbound: [String: NSObject] = [:]
            var candidatePair: [String: NSObject] = [:]
            for statistic in report.statistics.values {
                if statistic.type == "inbound-rtp", statistic.values["kind"] as? String == "video" {
                    inbound = statistic.values
                } else if statistic.type == "candidate-pair",
                    statistic.values["nominated"] as? Bool == true,
                    statistic.values["state"] as? String == "succeeded"
                {
                    candidatePair = statistic.values
                }
            }
            guard !inbound.isEmpty else { return nil }
            func value(_ key: String) -> Double { (inbound[key] as? NSNumber)?.doubleValue ?? 0 }
            let counters = relay.presentationCounters()
            return NativeReceiverSample(
                atMillis: Int64(ProcessInfo.processInfo.systemUptime * 1_000),
                framesDecoded: value("framesDecoded"), totalDecodeTime: value("totalDecodeTime"),
                jitterBufferEmittedCount: value("jitterBufferEmittedCount"),
                jitterBufferDelay: value("jitterBufferDelay"), packetsLost: value("packetsLost"),
                packetsReceived: value("packetsReceived"), presented: counters.frames,
                renderMilliseconds: counters.milliseconds,
                jitterSeconds: (inbound["jitter"] as? NSNumber)?.doubleValue ?? 0,
                roundTripSeconds: (candidatePair["currentRoundTripTime"] as? NSNumber)?.doubleValue ?? 0,
                decoderImplementation: (inbound["decoderImplementation"] as? String) ?? "")
        }
        func updateFrameGate(
            token: Int64, displayGeneration: Int64, mediaGeneration: Int64,
            mediaTimestamp: Int64
        ) {
            relay.updateFrameGate(
                token: token, displayGeneration: displayGeneration,
                mediaGeneration: mediaGeneration,
                mediaTimestamp: UInt32(truncatingIfNeeded: mediaTimestamp))
        }
        func resetVideo() { relay.reset() }

        func close() {
            guard !closed else { return }
            closed = true
            videoTrack?.remove(relay)
            videoTrack = nil
            channels.values.forEach { $0.close() }
            channels.removeAll()
            channelLabels.removeAll()
            peer.close()
            relay.clearFrameGate()
        }

        private func use(_ track: RTCVideoTrack) {
            guard videoTrack !== track else { return }
            videoTrack?.remove(relay)
            videoTrack = track
            track.add(relay)
        }
    }

    extension IOSScreenMediaEngine: RTCPeerConnectionDelegate {
        func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
            if let track = stream.videoTracks.first { use(track) }
        }
        func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
        func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
            var value = Dieter_V1_RemoteDesktopICECandidate()
            value.candidate = candidate.sdp
            value.sdpMid = candidate.sdpMid ?? ""
            value.sdpMlineIndex = candidate.sdpMLineIndex
            if let data = try? value.serializedData() { events.localCandidate(candidate: data) }
        }
        func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
            let state: Int32 =
                switch newState {
                case .new: 0
                case .connecting: 1
                case .connected: 2
                case .disconnected: 3
                case .failed: 4
                case .closed: 5
                @unknown default: 4
                }
            events.peerState(state: state)
        }
        func peerConnection(
            _ peerConnection: RTCPeerConnection,
            didAdd rtpReceiver: RTCRtpReceiver,
            streams: [RTCMediaStream]
        ) {
            if let track = rtpReceiver.track as? RTCVideoTrack { use(track) }
        }
    }

    extension IOSScreenMediaEngine: RTCDataChannelDelegate {
        func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
            guard let label = channelLabels[ObjectIdentifier(dataChannel)] else { return }
            events.channelState(label: label, open: dataChannel.readyState == .open)
        }
        func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
            guard buffer.isBinary, let label = channelLabels[ObjectIdentifier(dataChannel)] else { return }
            events.channelMessage(label: label, bytes: buffer.data)
        }
    }

    private enum IOSScreenMediaError: LocalizedError {
        case peerCreation, channelCreation(String), transceiverCreation, codecUnavailable
        var errorDescription: String? {
            switch self {
            case .peerCreation: "WebRTC could not create a peer connection."
            case .channelCreation(let name): "WebRTC could not create the \(name) data channel."
            case .transceiverCreation: "WebRTC could not create a receive-only video track."
            case .codecUnavailable: "This device has no compatible H.264 decoder."
            }
        }
    }

    private final class IOSRemoteDesktopVideoRelay: NSObject, RTCVideoRenderer, @unchecked Sendable {
        private let lock = NSLock()
        private weak var renderer: (any RTCVideoRenderer)?
        private var size = CGSize.zero
        private var events: NativeScreenMediaEvents?
        private var frameEpoch: Int64 = -1
        private var displayGeneration: Int64 = 0
        private var mediaGeneration: Int64 = 0
        private var mediaTimestamp: UInt32 = 0
        private var pendingFrame: RTCVideoFrame?
        private var framesPresented: Int64 = 0
        private var totalRenderMilliseconds = 0.0

        func setEvents(_ events: NativeScreenMediaEvents) {
            lock.withLock {
                self.events = events
                framesPresented = 0
                totalRenderMilliseconds = 0
            }
        }

        func presentationCounters() -> (frames: Int64, milliseconds: Double) {
            lock.withLock { (framesPresented, totalRenderMilliseconds) }
        }

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
        func reset() {
            let renderer = lock.withLock {
                pendingFrame = nil
                return self.renderer
            }
            renderer?.renderFrame(nil)
        }
        func updateFrameGate(
            token: Int64, displayGeneration: Int64, mediaGeneration: Int64,
            mediaTimestamp: UInt32
        ) {
            let output = lock.withLock {
                () -> (RTCVideoFrame, (any RTCVideoRenderer)?, NativeScreenMediaEvents?)? in
                if token != frameEpoch { pendingFrame = nil }
                frameEpoch = token
                self.displayGeneration = displayGeneration
                self.mediaGeneration = mediaGeneration
                self.mediaTimestamp = mediaTimestamp
                guard frameGateReady, let frame = pendingFrame else { return nil }
                pendingFrame = nil
                guard belongsToCurrentGeneration(frame) else { return nil }
                return (frame, renderer, events)
            }
            if let output { present(output) }
        }
        func clearFrameGate() {
            lock.withLock {
                pendingFrame = nil
                frameEpoch = -1
                displayGeneration = 0
                mediaGeneration = 0
                mediaTimestamp = 0
            }
        }
        func renderFrame(_ frame: RTCVideoFrame?) {
            let frame = frame.map { frame in
                let timestamp = IOSRemoteDesktopFrameTimestamp.nanoseconds(
                    decodedNanoseconds: frame.timeStampNs, rtpTimestamp: frame.timeStamp)
                guard timestamp != frame.timeStampNs else { return frame }
                let normalized = RTCVideoFrame(buffer: frame.buffer, rotation: frame.rotation, timeStampNs: timestamp)
                normalized.timeStamp = frame.timeStamp
                return normalized
            }
            guard let frame else {
                lock.withLock { renderer }?.renderFrame(nil)
                return
            }
            let timestamp = Int64(UInt64(UInt32(bitPattern: frame.timeStamp)))
            lock.withLock { events }?.decoded(rtpTimestamp: timestamp)
            let output = lock.withLock {
                () -> (RTCVideoFrame, (any RTCVideoRenderer)?, NativeScreenMediaEvents?)? in
                guard frameEpoch >= 0 else { return nil }
                guard frameGateReady else {
                    pendingFrame = frame
                    return nil
                }
                guard belongsToCurrentGeneration(frame) else { return nil }
                return (frame, renderer, events)
            }
            if let output { present(output) }
        }

        private var frameGateReady: Bool {
            displayGeneration > 0 && mediaGeneration == displayGeneration
        }

        private func belongsToCurrentGeneration(_ frame: RTCVideoFrame) -> Bool {
            let timestamp = UInt32(bitPattern: frame.timeStamp)
            return Int32(bitPattern: timestamp &- mediaTimestamp) >= 0
        }

        private func present(
            _ output: (RTCVideoFrame, (any RTCVideoRenderer)?, NativeScreenMediaEvents?)
        ) {
            let (frame, renderer, events) = output
            let started = ProcessInfo.processInfo.systemUptime
            renderer?.renderFrame(frame)
            if renderer != nil {
                let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
                lock.withLock {
                    framesPresented += 1
                    totalRenderMilliseconds += milliseconds
                }
                events?.presented(
                    rtpTimestamp: Int64(UInt64(UInt32(bitPattern: frame.timeStamp))))
            }
        }
    }
#endif

enum IOSRemoteDesktopFrameTimestamp {
    private static let rtpClockRate: UInt64 = 90_000
    private static let nanosecondsPerSecond: UInt64 = 1_000_000_000

    static func nanoseconds(decodedNanoseconds: Int64, rtpTimestamp: Int32) -> Int64 {
        guard decodedNanoseconds == 0 else { return decodedNanoseconds }
        let ticks = UInt64(UInt32(bitPattern: rtpTimestamp)) + 1
        return Int64(ticks * nanosecondsPerSecond / rtpClockRate)
    }
}
