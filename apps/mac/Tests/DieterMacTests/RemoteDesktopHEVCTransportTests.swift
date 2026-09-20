import DieterAPI
import DieterClient
import DieterCore
import Foundation
import Testing
@preconcurrency import WebRTC
@testable import DieterMac

// No window, input injection, screen capture, operator app or live daemon. This
// proves the pinned native SDK's HEVC RTP receive path against the real Go server.
@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment["DIETER_TEST_SCREEN_FIXTURE"] != nil
            && ProcessInfo.processInfo.environment["DIETER_TEST_CAPTURE_HELPER"] != nil,
        "Requires the disposable native screen fixture"))
@MainActor func remoteDesktopHEVCAuthenticatedTransport() async throws {
    try await exerciseRecoveryTransport(codec: "H265", mode: "clean")
}
@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment["DIETER_TEST_SCREEN_RECOVERY"] == "1"
            && ProcessInfo.processInfo.environment["DIETER_TEST_SCREEN_FIXTURE"] != nil,
        "Requires the explicit native recovery matrix"))
@MainActor func remoteDesktopRecoveryAuthenticatedTransport() async throws {
    guard ProcessInfo.processInfo.environment["DIETER_TEST_SCREEN_RECOVERY"] == "1" else { return }
    for codec in (envRecovery("DIETER_TEST_RECOVERY_CODECS") ?? ["H264", "H265"]) {
        for mode in (envRecovery("DIETER_TEST_RECOVERY_MODES") ?? ["baseline", "ltr", "fec", "both"]) {
            try await exerciseRecoveryTransport(codec: codec, mode: mode)
        }
    }
}
private func envRecovery(_ name: String) -> [String]? {
    ProcessInfo.processInfo.environment[name]?.split(separator: ",").map(String.init)
}
@MainActor private func exerciseRecoveryTransport(codec: String, mode: String) async throws {
    let env = ProcessInfo.processInfo.environment
    guard let fixturePath = env["DIETER_TEST_SCREEN_FIXTURE"], let helper = env["DIETER_TEST_CAPTURE_HELPER"] else {
        return
    }
    let directory = FileManager.default.temporaryDirectory.appending(path: "dieter-hevc-transport-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let ready = directory.appending(path: "ready.json"), log = directory.appending(path: "fixture.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let output = try FileHandle(forWritingTo: log)
    let process = Process(); process.executableURL = URL(fileURLWithPath: fixturePath)
    process.arguments = ["--helper", helper, "--source", "native-synthetic", "--authenticate", "--ready", ready.path]
    process.standardOutput = output; process.standardError = output
    var environment = env
    environment["DIETER_SCREEN_FEC"] = ["fec", "both", "clean"].contains(mode) ? "1" : "0"
    process.environment = environment
    try process.run()
    defer {
        if process.isRunning { process.terminate(); process.waitUntilExit() }; try? output.close();
        print("HEVC transport evidence: \(directory.path)")
    }
    try await hevcWait { FileManager.default.fileExists(atPath: ready.path) }
    let connection = try JSONDecoder().decode(HEVCFixture.self, from: Data(contentsOf: ready))
    let rpc = try DieterRPC(endpoint: #require(DieterEndpoint.parse(connection.url)), accessToken: connection.token)
    let rpcTask = Task { try await rpc.run() }
    defer { rpcTask.cancel() }
    let caps = try await rpc.remoteDesktopCapabilities()
    try #require(caps.codecModes.contains { $0.codec == "H265" })
    let frames = HEVCFrameCount()
    let pump = RemoteDesktopFeedbackPump()
    let references = RemoteDesktopReferenceReceiver { pump.acknowledge($0) }
    defer { references.stop(); pump.stop() }
    let factory = RTCPeerConnectionFactory(
        encoderFactory: RTCDefaultVideoEncoderFactory(),
        decoderFactory: RemoteDesktopDecoderFactory(
            onDecodedFrame: {
                frames.add($0); references.decoded(timestamp: UInt32(bitPattern: $0.timeStamp))
            }, enableHEVC: true))
    let delegate = HEVCTransportDelegate(references: references)
    let configuration = RTCConfiguration(); configuration.sdpSemantics = .unifiedPlan
    let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    let peer = try #require(factory.peerConnection(with: configuration, constraints: constraints, delegate: delegate))
    defer { peer.close() }
    let channel = peer.dataChannel(forLabel: "dieter-session-v1", configuration: RTCDataChannelConfiguration())
    channel?.delegate = delegate
    let receive = RTCRtpTransceiverInit(); receive.direction = .recvOnly
    let video = try #require(peer.addTransceiver(of: .video, init: receive))
    let codecs = factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs.filter {
        $0.name == codec || $0.name == "flexfec-03"
    }
    try #require(!codecs.isEmpty, "Pinned WebRTC binary must expose the custom HEVC decoder")
    try video.setCodecPreferences(codecs, error: ())
    let canReference = try remoteDesktopEnableReferenceDependencies(video)
    let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
        peer.offer(for: constraints) { value, error in
            if let error {
                continuation.resume(throwing: error)
            } else if let value {
                continuation.resume(returning: value)
            } else {
                continuation.resume(throwing: HEVCTransportError.missingOffer)
            }
        }
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        peer.setLocalDescription(offer) { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
    }
    try await hevcWait { peer.iceGatheringState == .complete }
    var request = Dieter_V1_StartRemoteDesktopRequest()
    request.referenceRecovery = canReference && ["ltr", "both"].contains(mode)
    request.codecPreference = codec == "H265" ? .hevc : .h264; request.clientNonce = UUID().uuidString
    request.rtcConfiguration = try Dieter_Gateway_V1_RTCConfiguration(serializedBytes: connection.rtc)
    request.displayID = try #require(caps.displays.first).id
    request.inputProtocolVersion = DieterContract.number
    request.maxWidth = 1920; request.maxHeight = 1080; request.maxFps = 60; request.maxBitrateKbps = 6000
    request.offer.type = "offer"; request.offer.sdp = try #require(peer.localDescription).sdp
    let signaling = HEVCTransportSignaling(
        peer: peer, request: request, certificate: connection.certificate, pump: pump, channel: channel)
    let signalTask = Task {
        do { try await rpc.startRemoteDesktop(request) { try await signaling.receive($0) } } catch {
            signaling.failure = String(describing: error)
        }
    }
    defer { signalTask.cancel() }
    let statisticsTask = Task { @MainActor in
        while !Task.isCancelled {
            if signaling.applied, let binding = signaling.binding {
                let report: RTCStatisticsReport = await withCheckedContinuation { continuation in
                    peer.statistics { continuation.resume(returning: $0) }
                }
                var feedback = Dieter_V1_RemoteDesktopReceiverFeedback()
                feedback.protocolVersion = DieterContract.number; feedback.inputEpoch = binding.inputEpoch
                for stat in report.statistics.values
                where stat.type == "candidate-pair" && (stat.values["state"] as? String) == "succeeded" {
                    feedback.rttMs = ((stat.values["currentRoundTripTime"] as? NSNumber)?.doubleValue ?? 0) * 1000
                }
                feedback.framesPerSecond = 60
                pump.update(feedback)
            }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
        }
    }
    defer { statisticsTask.cancel() }
    try await hevcWait { frames.count >= 60 || signaling.failure != nil }
    try #require(signaling.failure == nil, "\(signaling.failure ?? "")")
    #expect(frames.count >= 60)
    #expect(frames.native && frames.width == 1920 && frames.height == 1080)
    #expect(signaling.codec == codec)
    if mode != "clean" {
        if request.referenceRecovery { try await hevcWait { delegate.state.referenceAcks > 0 } }
        let keysBefore = await keyFrameCount(peer)
        let before = frames.count
        let started = ProcessInfo.processInfo.systemUptime
        try await mediaLoss(connection, mode: "burst")
        try await hevcWait { frames.count >= before + 45 || signaling.failure != nil }
        try #require(signaling.failure == nil, "\(signaling.failure ?? "")")
        if request.referenceRecovery { try await hevcWait { delegate.state.referenceRecoveries > 0 } }
        if request.referenceRecovery {
            let keysAfter = await keyFrameCount(peer);
            try #require(
                keysAfter == keysBefore, "Recovery must decode without an IDR: before=\(keysBefore) after=\(keysAfter)")
        }
        print(
            "RECOVERY codec=\(codec) mode=\(mode) burst_elapsed=\(ProcessInfo.processInfo.systemUptime-started) max_gap_ms=\(frames.maxGapMS) LTR_frames=\(delegate.state.referenceRecoveryFrames)"
        )
        try await mediaLoss(connection, mode: "random")
        try await Task.sleep(for: .seconds(6))
        if ["fec", "both"].contains(mode) {
            try #require(delegate.state.fecPackets > 0, "Adaptive FEC must transmit negotiated repairs")
        }
        print(
            "RECOVERY codec=\(codec) mode=\(mode) frames=\(frames.count) max_gap_ms=\(frames.maxGapMS) FEC_packets=\(delegate.state.fecPackets) FEC_bytes=\(delegate.state.fecBytes) LTR_frames=\(delegate.state.referenceRecoveryFrames)"
        )
        if ["fec", "both"].contains(mode) {
            try await hevcWait { delegate.state.fecPercent > 0 }
            try await mediaLoss(connection, mode: "fec-proof")
            var repaired: UInt32 = 0
            for _ in 0..<60 {
                var probe = URLRequest(url: URL(string: connection.url + "/test/media-loss")!);
                probe.setValue("Bearer " + connection.token, forHTTPHeaderField: "Authorization")
                let (data, _) = try await URLSession.shared.data(for: probe)
                repaired =
                    ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["repairedTimestamp"] as? NSNumber)?
                    .uint32Value ?? 0
                if repaired != 0 { break }; try await Task.sleep(for: .milliseconds(25))
            }
            try #require(repaired != 0, "Fixture must drop a protected packet")
            try await hevcWait { frames.contains(repaired) }
            print(
                "FEC PROOF codec=\(codec) decoded RTP timestamp=\(repaired) with original and retransmissions discarded"
            )
            try await mediaLoss(connection, mode: "none")
        }
        let stats: RTCStatisticsReport = await withCheckedContinuation { continuation in
            peer.statistics { continuation.resume(returning: $0) }
        }
        for value in stats.statistics.values where value.type == "inbound-rtp" {
            print("RECOVERY receiver \(value.values)")
        }
        try #require(frames.count > before + 100, "Decoder must keep advancing under loss")
    }
    try await rpc.closeRemoteDesktop(sessionID: signaling.sessionID)
}

private struct HEVCFixture: Decodable { var url: String; var certificate: Data; var rtc: Data; var token: String }
@MainActor private func keyFrameCount(_ peer: RTCPeerConnection) async -> Int {
    let stats: RTCStatisticsReport = await withCheckedContinuation { continuation in
        peer.statistics { continuation.resume(returning: $0) }
    }
    return stats.statistics.values.filter { $0.type == "inbound-rtp" }.reduce(0) {
        $0 + (($1.values["keyFramesDecoded"] as? NSNumber)?.intValue ?? 0)
    }
}
@MainActor private func mediaLoss(_ fixture: HEVCFixture, mode: String) async throws {
    var request = URLRequest(url: URL(string: fixture.url + "/test/media-loss?mode=" + mode)!)
    request.httpMethod = "POST"; request.setValue("Bearer " + fixture.token, forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    try #require((response as? HTTPURLResponse)?.statusCode == 200)
    print("Recovery fault: \(String(decoding: data, as: UTF8.self))")
}
private enum HEVCTransportError: Error { case missingOffer, timeout }
@MainActor private func hevcWait(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(15)
    while !condition() {
        if Date() >= deadline { throw HEVCTransportError.timeout }; try await Task.sleep(for: .milliseconds(25))
    }
}
private final class HEVCFrameCount: @unchecked Sendable {
    private let lock = NSLock()
    private var timestamps: [UInt32] = []
    func contains(_ timestamp: UInt32) -> Bool { lock.withLock { timestamps.contains(timestamp) } }
    private var value = 0
    private var lastAt: TimeInterval = 0, gap: Double = 0
    var maxGapMS: Double { lock.withLock { gap * 1000 } }
    private var nativeValue = true, widthValue: Int32 = 0, heightValue: Int32 = 0
    var native: Bool { lock.lock(); defer { lock.unlock() }; return nativeValue }
    var width: Int32 { lock.lock(); defer { lock.unlock() }; return widthValue }
    var height: Int32 { lock.lock(); defer { lock.unlock() }; return heightValue }
    func add(_ frame: RTCVideoFrame) {
        lock.lock(); defer { lock.unlock() }
        timestamps.append(UInt32(bitPattern: frame.timeStamp)); if timestamps.count > 256 { timestamps.removeFirst() }
        let now = ProcessInfo.processInfo.systemUptime; if lastAt > 0 { gap = max(gap, now - lastAt) }; lastAt = now
        value += 1; nativeValue = nativeValue && frame.buffer is RTCCVPixelBuffer; widthValue = frame.width;
        heightValue = frame.height
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
@MainActor private final class HEVCTransportSignaling {
    let pump: RemoteDesktopFeedbackPump
    let channel: RTCDataChannel?
    let peer: RTCPeerConnection, request: Dieter_V1_StartRemoteDesktopRequest, certificate: Data
    var binding: Dieter_V1_RemoteDesktopSessionBinding?, answer: String?, sessionID = "", codec = "", failure: String?
    var applied = false, candidates: [RTCIceCandidate] = []
    init(
        peer: RTCPeerConnection, request: Dieter_V1_StartRemoteDesktopRequest, certificate: Data,
        pump: RemoteDesktopFeedbackPump, channel: RTCDataChannel?
    ) {
        self.pump = pump; self.channel = channel
        self.peer = peer; self.request = request; self.certificate = certificate
    }
    func receive(_ signal: Dieter_V1_RemoteDesktopSignal) async throws {
        sessionID = signal.sessionID
        switch signal.payload {
        case .binding(let value): binding = value
        case .description_p(let value): answer = value.sdp
        case .candidate(let value):
            let candidate = RTCIceCandidate(
                sdp: value.candidate, sdpMLineIndex: value.sdpMlineIndex, sdpMid: value.sdpMid)
            if applied { try await peer.add(candidate) } else { candidates.append(candidate) }
        case .state(let value): codec = value.codec; if value.phase == "closed" { failure = value.reason }
        case .error(let value): failure = value.message
        default: break
        }
        if !applied, let binding, let answer {
            try RemoteDesktopSessionTrust.verify(
                binding: binding, sessionID: sessionID, clientNonce: request.clientNonce,
                offerSDP: request.offer.sdp, answerSDP: answer, daemonCertificatePEM: certificate)
            try #require(
                !binding.controlGranted && binding.displayID == request.displayID
                    && binding.inputProtocolVersion == DieterContract.number)
            var initial = Dieter_V1_RemoteDesktopReceiverFeedback(); initial.protocolVersion = DieterContract.number;
            initial.inputEpoch = binding.inputEpoch
            pump.start(channel: channel, initial: initial)
            try await peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer))
            applied = true
            for candidate in candidates { try await peer.add(candidate) }; candidates.removeAll()
        }
    }
}
private final class HEVCTransportDelegate: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate,
    @unchecked Sendable
{
    let references: RemoteDesktopReferenceReceiver
    private let lock = NSLock()
    private var latest = Dieter_V1_RemoteDesktopSessionState()
    var state: Dieter_V1_RemoteDesktopSessionState { lock.withLock { latest } }
    init(references: RemoteDesktopReferenceReceiver) { self.references = references }
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let event = try? Dieter_V1_RemoteDesktopHostEvent(serializedBytes: buffer.data) else { return }
        switch event.payload {
        case .reference(let value): references.expect(value)
        case .state(let value): lock.withLock { latest = value }
        default: break
        }
    }
    let sink = RemoteDesktopDecodedTrackSink()
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        stream.videoTracks.first?.add(sink)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    func peerConnection(
        _ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]
    ) {
        (rtpReceiver.track as? RTCVideoTrack)?.add(sink)
    }
}
