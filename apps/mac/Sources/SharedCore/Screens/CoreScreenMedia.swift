import DieterAPI
import DieterShared
import Foundation
import Synchronization
import VideoToolbox
@preconcurrency import WebRTC

/// Presentation counters a renderer keeps, readable from any thread.
package struct ScreenPresentationCounters: Sendable {
    package var framesPresented: UInt64
    package var totalRenderMilliseconds: Double

    package init(framesPresented: UInt64 = 0, totalRenderMilliseconds: Double = 0) {
        self.framesPresented = framesPresented
        self.totalRenderMilliseconds = totalRenderMilliseconds
    }
}

/// A screen view's picture: what draws the frames a screen engine decodes.
/// The engine takes a fresh `decodeHandler()` after each `reset()`, because
/// a reset invalidates the decode paths handed out before it.
@MainActor
package protocol ScreenRenderer: AnyObject {
    /// Clears the picture of a previous attempt.
    func reset()
    /// Where an engine delivers its decoded frames, on the decoder's thread.
    func decodeHandler() -> @Sendable (RTCVideoFrame) -> Void
    /// Called for each frame shown on screen.
    var onFramePresented: (@MainActor (RTCVideoFrame) -> Void)? { get set }
    /// Called when the renderer cannot draw.
    var onFailure: (@MainActor (String) -> Void)? { get set }
    nonisolated var presentationCounters: ScreenPresentationCounters { get }
    /// The core's frame gate for the current display; renderers that draw
    /// every decoded frame ignore it.
    nonisolated func updateFrameGate(
        token: Int64, displayGeneration: Int64, mediaGeneration: Int64, mediaTimestamp: Int64)
    /// A new display started; renderers that hold frames drop them.
    nonisolated func resetVideo()
}

extension ScreenRenderer {
    package nonisolated func updateFrameGate(
        token: Int64, displayGeneration: Int64, mediaGeneration: Int64, mediaTimestamp: Int64
    ) {}
    package nonisolated func resetVideo() {}
}

/// The WebRTC stack for the shared core's screen sessions: one peer
/// connection per attempt, hardware decoders into the view's renderer, and
/// data channels. The core drives it and owns signaling, trust, the lease,
/// recovery, input, clipboard sync, and display matching. Each screen view
/// attaches its renderer under the scope it observes the core with, before
/// it observes `SLICE_SCREEN` there.
package final class CoreScreenMedia: NSObject, NativeScreenMedia, Sendable {
    private let surfaces = Mutex<[String: CoreScreenSurface]>([:])
    private let rendererUnavailable: @Sendable () -> String?

    /// `rendererUnavailable` says why this device cannot draw screens, or nil.
    package init(rendererUnavailable: @escaping @Sendable () -> String? = { nil }) {
        self.rendererUnavailable = rendererUnavailable
    }

    /// Renders the engines the core creates for `scope` into `renderer`, and
    /// reports the media path (direct or relayed) as statistics arrive.
    @MainActor package func attach(
        scope: String, renderer: any ScreenRenderer, mediaRoute: @escaping @MainActor (String) -> Void
    ) {
        let surface = CoreScreenSurface(renderer: renderer, mediaRoute: mediaRoute)
        renderer.onFramePresented = { [weak surface] frame in surface?.presented(frame) }
        renderer.onFailure = { [weak surface] message in surface?.failed(message) }
        surfaces.withLock { $0[scope] = surface }
    }

    @MainActor package func detach(scope: String) {
        guard let surface = surfaces.withLock({ $0.removeValue(forKey: scope) }) else { return }
        surface.renderer.onFramePresented = nil
        surface.renderer.onFailure = nil
    }

    package func capabilities() -> Data {
        var value = ClientScreenMediaCapabilities()
        value.receiveCodecs = Self.receiveCodecs
        value.hevcDecoder = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        value.referenceDependencies = true
        value.millisecondTimestamps = false
        if let failure = rendererUnavailable() { value.initializationFailure = failure }
        return (try? value.serializedData()) ?? Data()
    }

    package func create(
        configuration: Data, scope: String, events: NativeScreenMediaEvents
    ) -> any NativeScreenMediaEngine {
        let surface = surfaces.withLock { $0[scope] }
        let decode = surface?.begin()
        let engine = CoreScreenMediaEngine(
            configuration: configuration, surface: surface, decode: decode, events: NativeCallback(events))
        surface?.adopt(engine)
        return engine
    }

    /// What this device can decode, as libwebrtc names it; probed once.
    private static let receiveCodecs: [ClientRtpCodec] = {
        let factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RemoteDesktopDecoderFactory(enableHEVC: true))
        return factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs.map { codec in
            ClientRtpCodec.with {
                $0.name = codec.name
                $0.profile = codec.parameters["profile-level-id"] ?? ""
            }
        }
    }()
}

/// One screen view's renderer and the engine currently drawing into it.
package final class CoreScreenSurface: @unchecked Sendable {
    /// Only touched on the main actor, except its presentation counters and frame gate.
    nonisolated(unsafe) let renderer: any ScreenRenderer
    private let mediaRoute: @MainActor (String) -> Void
    private let lock = NSLock()
    private weak var current: CoreScreenMediaEngine?

    @MainActor init(renderer: any ScreenRenderer, mediaRoute: @escaping @MainActor (String) -> Void) {
        self.renderer = renderer
        self.mediaRoute = mediaRoute
    }

    /// Clears the previous attempt's picture and returns a decode path for a
    /// new engine. A reset invalidates earlier decode paths, so each engine
    /// takes its own after it.
    func begin() -> @Sendable (RTCVideoFrame) -> Void {
        onMainThread { [renderer] in
            renderer.reset()
            return renderer.decodeHandler()
        }
    }

    func adopt(_ engine: CoreScreenMediaEngine) { lock.withLock { current = engine } }

    func isCurrent(_ engine: CoreScreenMediaEngine) -> Bool { lock.withLock { current === engine } }

    /// Forgets `engine` and clears the picture, unless a newer engine has
    /// already taken the view over.
    func release(_ engine: CoreScreenMediaEngine) {
        let owned = lock.withLock {
            guard current === engine else { return false }
            current = nil
            return true
        }
        guard owned else { return }
        onMainThread { [self] in
            if lock.withLock({ current == nil }) { renderer.reset() }
        }
    }

    var presentationCounters: ScreenPresentationCounters { renderer.presentationCounters }

    @MainActor func presented(_ frame: RTCVideoFrame) { lock.withLock { current }?.presented(frame) }

    @MainActor func failed(_ message: String) { lock.withLock { current }?.rendererFailed(message) }

    func publish(route: String) {
        Task { @MainActor [mediaRoute] in mediaRoute(route) }
    }
}

/// One attempt's peer connection. Core calls arrive on its dispatcher and
/// WebRTC calls back on its own threads; nothing here makes a policy decision.
package final class CoreScreenMediaEngine: NSObject, NativeScreenMediaEngine, @unchecked Sendable {
    private let events: NativeCallback<NativeScreenMediaEvents>
    private let surface: CoreScreenSurface?
    private let closed = Atomic<Bool>(false)
    private var factory: RTCPeerConnectionFactory?
    private var peer: RTCPeerConnection?
    private var channels: [String: RTCDataChannel] = [:]
    private var channelDelegates: [CoreScreenChannelDelegate] = []
    private let peerDelegate = CoreScreenPeerDelegate()
    private let sink = RemoteDesktopDecodedTrackSink()
    private let lock = NSLock()
    private var videoTrack: RTCVideoTrack?
    private var setupFailure: String?

    init(
        configuration: Data, surface: CoreScreenSurface?, decode: (@Sendable (RTCVideoFrame) -> Void)?,
        events: NativeCallback<NativeScreenMediaEvents>
    ) {
        self.events = events
        self.surface = surface
        super.init()
        do {
            try setUp(try ClientScreenMediaConfig(serializedBytes: configuration), decode: decode)
        } catch {
            setupFailure = error.localizedDescription
        }
    }

    private func setUp(_ config: ClientScreenMediaConfig, decode: (@Sendable (RTCVideoFrame) -> Void)?) throws {
        guard let decode else { throw Self.failure("The screen view closed.") }
        let hevc = config.codecs.contains { $0.name.caseInsensitiveCompare("H265") == .orderedSame }
        let decoders = RemoteDesktopDecoderFactory(
            onDecodedFrame: { [weak self] frame in
                guard let self, !self.isClosed else { return }
                self.events.value.decoded(rtpTimestamp: Int64(UInt32(bitPattern: frame.timeStamp)))
                decode(frame)
            },
            enableHEVC: hevc,
            onHEVCUnavailable: { [weak self] in
                guard let self, !self.isClosed else { return }
                self.events.value.hevcUnavailable(reason: "HEVC decoder unavailable")
            })
        let factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: decoders)
        self.factory = factory
        let rtc = RTCConfiguration()
        rtc.sdpSemantics = .unifiedPlan
        rtc.continualGatheringPolicy = .gatherContinually
        rtc.iceServers = config.rtc.iceServers.map {
            RTCIceServer(
                urlStrings: $0.urls, username: $0.username.isEmpty ? nil : $0.username,
                credential: $0.credential.isEmpty ? nil : $0.credential)
        }
        var relayOnly = config.relayOnly
        #if DEBUG
            relayOnly = relayOnly || ProcessInfo.processInfo.environment["DIETER_TEST_FORCE_TURN"] == "1"
        #endif
        if relayOnly { rtc.iceTransportPolicy = .relay }
        peerDelegate.engine = self
        guard
            let peer = factory.peerConnection(
                with: rtc, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
                delegate: peerDelegate)
        else { throw Self.failure("WebRTC could not create a peer connection.") }
        self.peer = peer
        for spec in config.channels {
            let options = RTCDataChannelConfiguration()
            options.isOrdered = spec.ordered
            if spec.hasMaxRetransmits { options.maxRetransmits = spec.maxRetransmits }
            guard let channel = peer.dataChannel(forLabel: spec.label, configuration: options) else {
                throw Self.failure("WebRTC could not open the \(spec.label) channel.")
            }
            let delegate = CoreScreenChannelDelegate(label: spec.label, engine: self)
            channel.delegate = delegate
            channelDelegates.append(delegate)
            channels[spec.label] = channel
        }
        let receive = RTCRtpTransceiverInit()
        receive.direction = .recvOnly
        guard let video = peer.addTransceiver(of: .video, init: receive) else {
            throw Self.failure("WebRTC could not create a receive-only video track.")
        }
        // The core chose and ordered the codecs; map them onto this factory's.
        let available = factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs
        let chosen = available.compactMap { capability -> (Int, RTCRtpCodecCapability)? in
            let rank = config.codecs.firstIndex { codec in
                codec.name.caseInsensitiveCompare(capability.name) == .orderedSame
                    && (codec.profile.isEmpty || codec.profile == capability.parameters["profile-level-id"])
            }
            return rank.map { ($0, capability) }
        }.sorted { $0.0 < $1.0 }.map(\.1)
        guard !chosen.isEmpty else {
            throw Self.failure(
                "Selected codec unavailable. HEVC requires hardware decoding and an updated host at up to 1080p60.")
        }
        try video.setCodecPreferences(chosen, error: ())
        if config.enableReferenceDependencies { _ = try remoteDesktopEnableReferenceDependencies(video) }
    }

    private var isClosed: Bool { closed.load(ordering: .acquiring) }

    package func createOffer(completion: any NativeScreenTextCompletion) {
        let completion = NativeCallback(completion)
        guard let peer, !isClosed else {
            completion.value.completed(text: nil, error: setupFailure ?? "The screen connection closed.")
            return
        }
        peer.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { offer, error in
            guard let offer else {
                completion.value.completed(text: nil, error: error?.localizedDescription ?? "The screen offer failed.")
                return
            }
            peer.setLocalDescription(offer) { error in
                if let error {
                    completion.value.completed(text: nil, error: error.localizedDescription)
                } else {
                    completion.value.completed(text: offer.sdp, error: nil)
                }
            }
        }
    }

    package func applyAnswer(sdp: String, completion: any NativeScreenDoneCompletion) {
        let completion = NativeCallback(completion)
        guard let peer, !isClosed else { completion.value.completed(error: "The screen connection closed."); return }
        peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { error in
            completion.value.completed(error: error.map { $0.localizedDescription })
        }
    }

    package func addRemoteCandidate(candidate: Data, completion: any NativeScreenDoneCompletion) {
        let completion = NativeCallback(completion)
        guard let peer, !isClosed, let value = try? Dieter_V1_RemoteDesktopICECandidate(serializedBytes: candidate)
        else {
            completion.value.completed(error: "Invalid ICE candidate")
            return
        }
        let ice = RTCIceCandidate(
            sdp: value.candidate, sdpMLineIndex: value.sdpMlineIndex, sdpMid: value.sdpMid.isEmpty ? nil : value.sdpMid)
        peer.add(ice) { error in completion.value.completed(error: error.map { $0.localizedDescription }) }
    }

    package func send(label: String, bytes: Data) -> Bool {
        guard !isClosed, let channel = channels[label], channel.readyState == .open else { return false }
        return channel.sendData(RTCDataBuffer(data: bytes, isBinary: true))
    }

    package func isOpen(label: String) -> Bool { !isClosed && channels[label]?.readyState == .open }

    package func bufferedAmount(label: String) -> Int64 { Int64(clamping: channels[label]?.bufferedAmount ?? 0) }

    package func statistics(completion: any NativeScreenSampleCompletion) {
        let completion = NativeCallback(completion)
        guard let peer, let surface, !isClosed else { completion.value.completed(sample: nil); return }
        Task {
            let report = await peer.statistics()
            var inbound: [String: NSObject] = [:]
            var pair: [String: NSObject] = [:]
            for statistic in report.statistics.values {
                if statistic.type == "inbound-rtp", statistic.values["kind"] as? String == "video" {
                    inbound = statistic.values
                } else if statistic.type == "candidate-pair", statistic.values["nominated"] as? Bool == true,
                    statistic.values["state"] as? String == "succeeded"
                {
                    pair = statistic.values
                }
            }
            func number(_ values: [String: NSObject], _ key: String) -> Double {
                (values[key] as? NSNumber)?.doubleValue ?? 0
            }
            if let local = pair["localCandidateId"] as? String, let remote = pair["remoteCandidateId"] as? String {
                let types = [local, remote].compactMap { report.statistics[$0]?.values["candidateType"] as? String }
                surface.publish(route: types.contains("relay") ? "Relayed media" : "Direct media")
            }
            let rendered = surface.presentationCounters
            completion.value.completed(
                sample: NativeReceiverSample(
                    atMillis: Int64(ProcessInfo.processInfo.systemUptime * 1000),
                    framesDecoded: number(inbound, "framesDecoded"),
                    totalDecodeTime: number(inbound, "totalDecodeTime"),
                    jitterBufferEmittedCount: number(inbound, "jitterBufferEmittedCount"),
                    jitterBufferDelay: number(inbound, "jitterBufferDelay"),
                    packetsLost: number(inbound, "packetsLost"),
                    packetsReceived: number(inbound, "packetsReceived"),
                    presented: Int64(clamping: rendered.framesPresented),
                    renderMilliseconds: rendered.totalRenderMilliseconds, jitterSeconds: number(inbound, "jitter"),
                    roundTripSeconds: number(pair, "currentRoundTripTime"),
                    decoderImplementation: inbound["decoderImplementation"] as? String ?? ""))
        }
    }

    /// The core gates readiness on presented RTP timestamps; a renderer that
    /// draws every decoded frame has nothing to hold.
    package func updateFrameGate(token: Int64, displayGeneration: Int64, mediaGeneration: Int64, mediaTimestamp: Int64)
    {
        guard !isClosed else { return }
        surface?.renderer.updateFrameGate(
            token: token, displayGeneration: displayGeneration, mediaGeneration: mediaGeneration,
            mediaTimestamp: mediaTimestamp)
    }

    /// A new display; a renderer that draws every frame keeps the previous
    /// picture until the display's first frame arrives.
    package func resetVideo() {
        guard !isClosed else { return }
        surface?.renderer.resetVideo()
    }

    package func close() {
        guard !closed.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let (track, channels, peer) = lock.withLock { (videoTrack, self.channels, self.peer) }
        track?.remove(sink)
        for channel in channels.values {
            channel.delegate = nil
            channel.close()
        }
        peer?.close()
        surface?.release(self)
    }

    // MARK: Callbacks

    fileprivate func received(track: RTCVideoTrack) {
        guard !isClosed else { return }
        let previous = lock.withLock {
            let previous = videoTrack
            videoTrack = track
            return previous
        }
        guard previous?.isEqual(track) != true else { return }
        previous?.remove(sink)
        track.add(sink)
    }

    fileprivate func generated(_ candidate: RTCIceCandidate) {
        guard !isClosed else { return }
        var value = Dieter_V1_RemoteDesktopICECandidate()
        value.candidate = candidate.sdp
        value.sdpMid = candidate.sdpMid ?? ""
        value.sdpMlineIndex = candidate.sdpMLineIndex
        guard let data = try? value.serializedData() else { return }
        events.value.localCandidate(candidate: data)
    }

    fileprivate func peerChanged(_ state: RTCPeerConnectionState) {
        guard !isClosed else { return }
        // The core's PeerState: new, connecting, connected, disconnected, failed, closed.
        let ordinal: Int32 =
            switch state {
            case .new: 0
            case .connecting: 1
            case .connected: 2
            case .disconnected: 3
            case .failed: 4
            case .closed: 5
            @unknown default: 4
            }
        events.value.peerState(state: ordinal)
    }

    fileprivate func channelChanged(_ label: String, _ channel: RTCDataChannel) {
        guard !isClosed else { return }
        switch channel.readyState {
        case .open: events.value.channelState(label: label, open: true)
        case .closed: events.value.channelState(label: label, open: false)
        default: break
        }
    }

    fileprivate func channelMessage(_ label: String, _ buffer: RTCDataBuffer) {
        guard !isClosed, buffer.isBinary, buffer.data.count <= Self.maxMessageBytes else { return }
        events.value.channelMessage(label: label, bytes: buffer.data)
    }

    @MainActor fileprivate func presented(_ frame: RTCVideoFrame) {
        guard !isClosed else { return }
        events.value.presented(rtpTimestamp: Int64(UInt32(bitPattern: frame.timeStamp)))
    }

    @MainActor fileprivate func rendererFailed(_ message: String) {
        guard !isClosed else { return }
        events.value.failure(message: message)
    }

    private static let maxMessageBytes = 1 << 20

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "DieterScreens", code: 6, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class CoreScreenPeerDelegate: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    weak var engine: CoreScreenMediaEngine?

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if let track = stream.videoTracks.first { engine?.received(track: track) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        engine?.generated(candidate)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    // The host never opens channels; refuse any it tries.
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        dataChannel.close()
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        engine?.peerChanged(newState)
    }
    func peerConnection(
        _ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]
    ) {
        if let track = rtpReceiver.track as? RTCVideoTrack { engine?.received(track: track) }
    }
}

private final class CoreScreenChannelDelegate: NSObject, RTCDataChannelDelegate, @unchecked Sendable {
    let label: String
    weak var engine: CoreScreenMediaEngine?

    init(label: String, engine: CoreScreenMediaEngine) {
        self.label = label
        self.engine = engine
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) { engine?.channelChanged(label, dataChannel) }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        engine?.channelMessage(label, buffer)
    }
}

/// Runs `body` on the main thread and returns its result. The core calls the
/// media engine and pasteboards from its own threads; the main thread never
/// waits for the core, so this cannot deadlock.
package func onMainThread<T: Sendable>(_ body: @MainActor () -> T) -> T {
    if Thread.isMainThread { return MainActor.assumeIsolated(body) }
    return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
}
