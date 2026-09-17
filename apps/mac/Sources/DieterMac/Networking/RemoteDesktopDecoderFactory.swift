import Foundation
import VideoToolbox
@preconcurrency import WebRTC

// The bundled decoder accepts H.264 High, but its default SDP list advertises
// level 3.1. Advertise the hardware path's 4K60 / 1080p120 ceiling explicitly.
final class RemoteDesktopDecoderFactory: NSObject, RTCVideoDecoderFactory {
    private let underlying = RTCDefaultVideoDecoderFactory()
    private let onDecodedFrame: (@Sendable (RTCVideoFrame) -> Void)?
    private let enableHEVC: Bool
    private let onHEVCUnavailable: @Sendable () -> Void
    init(
        onDecodedFrame: (@Sendable (RTCVideoFrame) -> Void)? = nil, enableHEVC: Bool = false,
        onHEVCUnavailable: @escaping @Sendable () -> Void = {}
    ) {
        self.onDecodedFrame = onDecodedFrame; self.enableHEVC = enableHEVC; self.onHEVCUnavailable = onHEVCUnavailable
    }
    func supportedCodecs() -> [RTCVideoCodecInfo] {
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) else { return [] }
        var codecs = ["640034", "42e034"].map {
            RTCVideoCodecInfo(
                name: "H264",
                parameters: [
                    "profile-level-id": $0, "packetization-mode": "1", "level-asymmetry-allowed": "1",
                ])
        }
        if enableHEVC && VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
            codecs.insert(
                RTCVideoCodecInfo(
                    name: "H265",
                    parameters: ["profile-id": "1", "tier-flag": "0", "level-id": "153", "tx-mode": "SRST"]), at: 0)
        }
        return codecs
    }
    func createDecoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoDecoder)? {
        let decoder: any RTCVideoDecoder
        if info.name.caseInsensitiveCompare("H265") == .orderedSame {
            guard enableHEVC && VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) else { return nil }
            decoder = RemoteDesktopHEVCDecoder(onUnavailable: onHEVCUnavailable)
        } else {
            guard let value = underlying.createDecoder(info) else { return nil }; decoder = value
        }
        guard let onDecodedFrame else { return decoder }
        return RemoteDesktopImmediateDecoder(decoder, onDecodedFrame: onDecodedFrame)
    }
}

// Keep libwebrtc's callback for reference management/statistics, while presenting
// desktop output immediately. There is no audio clock to synchronize against.
private final class RemoteDesktopImmediateDecoder: NSObject, RTCVideoDecoder {
    let underlying: any RTCVideoDecoder
    let onDecodedFrame: @Sendable (RTCVideoFrame) -> Void
    init(_ underlying: any RTCVideoDecoder, onDecodedFrame: @escaping @Sendable (RTCVideoFrame) -> Void) {
        self.underlying = underlying; self.onDecodedFrame = onDecodedFrame
    }
    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) {
        underlying.setCallback { [onDecodedFrame] frame in
            onDecodedFrame(frame)
            callback(frame)
        }
    }
    func startDecode(withNumberOfCores numberOfCores: Int32) -> Int {
        underlying.startDecode(withNumberOfCores: numberOfCores)
    }
    func release() -> Int { underlying.release() }
    func decode(
        _ encodedImage: RTCEncodedImage, missingFrames: Bool, codecSpecificInfo info: (any RTCCodecSpecificInfo)?,
        renderTimeMs: Int64
    ) -> Int {
        underlying.decode(
            encodedImage, missingFrames: missingFrames, codecSpecificInfo: info, renderTimeMs: renderTimeMs)
    }
    func implementationName() -> String { underlying.implementationName() }
}

// A registered sink keeps the receive track active. Presentation happens in the
// decoder callback; the later scheduled callback must not draw the frame twice.
final class RemoteDesktopDecodedTrackSink: NSObject, RTCVideoRenderer {
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {}
}
