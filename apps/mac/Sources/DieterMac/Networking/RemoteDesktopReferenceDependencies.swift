import DieterAPI
import Foundation
@preconcurrency import WebRTC

let remoteDesktopGenericDescriptorURI = "http://www.webrtc.org/experiments/rtp-hdrext/generic-frame-descriptor-00"

// Negotiates the generic frame descriptor so the host can recover from lost
// references; the core acknowledges decoded references.
func remoteDesktopEnableReferenceDependencies(_ transceiver: RTCRtpTransceiver) throws -> Bool {
    let extensions = transceiver.headerExtensionsToNegotiate
    guard let descriptor = extensions.first(where: { $0.uri == remoteDesktopGenericDescriptorURI }) else {
        return false
    }
    descriptor.direction = .recvOnly
    try transceiver.setHeaderExtensionsToNegotiate(extensions)
    return true
}
