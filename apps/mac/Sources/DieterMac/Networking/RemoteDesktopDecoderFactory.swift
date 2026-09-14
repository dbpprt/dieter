import Foundation
import VideoToolbox
@preconcurrency import WebRTC

// The bundled decoder accepts H.264 High, but its default SDP list advertises
// level 3.1. Advertise the hardware path's 4K/60 ceiling explicitly.
final class RemoteDesktopDecoderFactory: NSObject, RTCVideoDecoderFactory {
    private let underlying = RTCDefaultVideoDecoderFactory()
    func supportedCodecs() -> [RTCVideoCodecInfo] {
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) else { return [] }
        return ["640034", "42e034"].map {
            RTCVideoCodecInfo(
                name: "H264",
                parameters: [
                    "profile-level-id": $0, "packetization-mode": "1", "level-asymmetry-allowed": "1",
                ])
        }
    }
    func createDecoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoDecoder)? {
        underlying.createDecoder(info)
    }
}
