import Foundation
import Testing
import VideoToolbox
@preconcurrency import WebRTC
@testable import DieterMac

@Test func remoteDesktopHEVCRejectsMalformedAccessUnits() {
    for bytes: [UInt8] in [
        [], [0, 0, 1], [0, 0, 1, 0x40], [0, 0, 1, 0xc0, 1],
        [0, 0, 1, 0x40, 0], [0, 0, 1, 0x41, 1], [0, 0, 1, 0x40, 9], [1, 0, 0, 1, 0x40, 1],
    ] {
        #expect(RemoteDesktopHEVCDecoder.nalUnits(Data(bytes)) == nil)
    }
    #expect(RemoteDesktopHEVCDecoder.nalUnits(Data([0, 0, 0, 1, 0x40, 1, 3, 0, 0, 1, 0x42, 1, 4]))?.count == 2)
    #expect(RemoteDesktopHEVCDecoder.nalUnits(Data([0, 0, 1, 0x40, 1]) + Data(repeating: 3, count: 65536)) == nil)
}

@Test func remoteDesktopHEVCRequiresExplicitOptIn() {
    #expect(!RemoteDesktopDecoderFactory().supportedCodecs().contains { $0.name == "H265" })
    let factory = RemoteDesktopDecoderFactory(enableHEVC: true)
    #expect(
        factory.supportedCodecs().contains { $0.name == "H265" } == VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC))
}

@Test func remoteDesktopHEVCHardwareDecodeAndRecovery() throws {
    guard let path = ProcessInfo.processInfo.environment["DIETER_TEST_HEVC_FRAMES"] else { return }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    var frames: [Data] = [], offset = 0
    while offset < data.count {
        try #require(offset + 4 <= data.count)
        let length = data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
        offset += 4
        try #require(length > 0 && length <= 16 * 1024 * 1024 && offset + length <= data.count)
        frames.append(data.subdata(in: offset..<offset + length)); offset += length
    }
    try #require(frames.count >= 120)
    let decoder = RemoteDesktopHEVCDecoder()
    #expect(decoder.startDecode(withNumberOfCores: 1) == 0)
    var decoded = 0
    decoder.setCallback { frame in
        #expect(frame.width == 1920 && frame.height == 1080)
        #expect(frame.buffer is RTCCVPixelBuffer)
        #expect(UInt32(bitPattern: frame.timeStamp) == UInt32(decoded + 1) * 1500)
        decoded += 1
    }
    for (index, bytes) in frames.enumerated() {
        let image = RTCEncodedImage(); image.buffer = bytes; image.timeStamp = UInt32(index + 1) * 1500
        #expect(decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0) == 0)
    }
    #expect(decoded == frames.count)
    let delta = RTCEncodedImage(); delta.buffer = frames[1]
    #expect(decoder.decode(delta, missingFrames: true, codecSpecificInfo: nil, renderTimeMs: 0) != 0)
    #expect(decoded == frames.count)
    let key = RTCEncodedImage(); key.buffer = frames[0]; key.timeStamp = UInt32(decoded + 1) * 1500
    #expect(decoder.decode(key, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0) == 0)
    #expect(decoded == frames.count + 1)
    #expect(decoder.release() == 0)
    #expect(decoder.release() == 0)
}
