import DieterAPI
import Foundation
import Testing
@preconcurrency import WebRTC
@testable import DieterMac

@Test @MainActor func remoteDesktopRecoveryCodecCapabilities() throws {
    let factory = RTCPeerConnectionFactory(
        encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RemoteDesktopDecoderFactory(enableHEVC: true))
    let config = RTCConfiguration(); config.sdpSemantics = .unifiedPlan
    let peer = try #require(factory.peerConnection(with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: nil))
    defer { peer.close() }
    let transceiver = try #require(peer.addTransceiver(of: .video))
    let names = factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs.map(\.name)
    #expect(try remoteDesktopEnableReferenceDependencies(transceiver))
    #expect(names.contains { $0.lowercased() == "flexfec-03" })
}

private final class ReferenceEvidence: @unchecked Sendable {
    let lock = NSLock()
    private var instant: TimeInterval = 1
    private var values: [Dieter_V1_RemoteDesktopReference] = []
    var now: TimeInterval { lock.withLock { instant } }
    var ids: [UInt64] { lock.withLock { values.map(\.frameID) } }
    func advance() { lock.withLock { instant += 2.001 } }
    func add(_ value: [Dieter_V1_RemoteDesktopReference]) { lock.withLock { values += value } }
}
private func reference(_ id: UInt64, _ timestamp: UInt32, generation: UInt64 = 1) -> Dieter_V1_RemoteDesktopReference {
    var value = Dieter_V1_RemoteDesktopReference()
    value.frameID = id; value.rtpTimestamp = timestamp; value.generation = generation
    return value
}
@Test func referenceDecoderAcknowledgmentOrderingAndExpiry() {
    let evidence = ReferenceEvidence()
    let receiver = RemoteDesktopReferenceReceiver(clock: { evidence.now }, acknowledge: { evidence.add($0) })
    receiver.expect(reference(1, 90_025))
    receiver.decoded(timestamp: 90_024)
    #expect(evidence.ids.isEmpty)
    receiver.decoded(timestamp: 90_025)
    receiver.decoded(timestamp: UInt32.max)
    receiver.expect(reference(2, UInt32.max))
    #expect(evidence.ids == [1, 2])
    evidence.advance()
    receiver.expect(reference(3, 90_025))
    #expect(evidence.ids == [1, 2])
    receiver.stop()
    receiver.decoded(timestamp: 90_025)
    receiver.expect(reference(4, 90_025))
    #expect(evidence.ids == [1, 2])
}
@Test func referenceChallengesBoundedAndGenerationScoped() {
    let evidence = ReferenceEvidence()
    let receiver = RemoteDesktopReferenceReceiver(clock: { evidence.now }, acknowledge: { evidence.add($0) })
    receiver.expect(reference(1, 90))
    evidence.advance()
    receiver.decoded(timestamp: 90)
    #expect(evidence.ids.isEmpty)
    for id in 2...10 { receiver.expect(reference(UInt64(id), UInt32(id * 90), generation: 2)) }
    receiver.decoded(timestamp: 180)
    receiver.expect(reference(11, 180, generation: 1))
    #expect(evidence.ids.isEmpty)
    receiver.decoded(timestamp: 900)
    #expect(evidence.ids == [10])
    receiver.expect(reference(12, 270, generation: 3))
    receiver.decoded(timestamp: 270)
    #expect(evidence.ids == [10, 12])
}
