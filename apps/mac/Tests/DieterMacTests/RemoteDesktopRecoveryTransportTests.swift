import DieterAPI
import Foundation
import Testing
@preconcurrency import WebRTC
@testable import DieterMac

@Test @MainActor func remoteDesktopRecoveryCodecCapabilities() throws {
    let factory = RTCPeerConnectionFactory(
        encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RemoteDesktopDecoderFactory(enableHEVC: true))
    let config = RTCConfiguration(); config.sdpSemantics = .unifiedPlan
    let peer = try #require(
        factory.peerConnection(
            with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: nil))
    defer { peer.close() }
    let transceiver = try #require(peer.addTransceiver(of: .video))
    let names = factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs.map(\.name)
    #expect(try remoteDesktopEnableReferenceDependencies(transceiver))
    #expect(names.contains { $0.lowercased() == "flexfec-03" })
}
