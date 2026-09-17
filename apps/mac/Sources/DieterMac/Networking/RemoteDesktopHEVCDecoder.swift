import Foundation
@preconcurrency import VideoToolbox
@preconcurrency import WebRTC

// libwebrtc in the pinned binary contains HEVC RTP support but no Objective-C
// decoder adapter. Keep decoding synchronous and hardware-required: one decode,
// no compressed-frame queue, and native NV12 surfaces for the existing renderer.
final class RemoteDesktopHEVCDecoder: NSObject, RTCVideoDecoder {
    private let lock = NSRecursiveLock()
    private var callback: RTCVideoDecoderCallback?
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameters: [Int: Data] = [:]
    private var needsKeyFrame = true
    private var decoded = false
    private let onUnavailable: @Sendable () -> Void

    init(onUnavailable: @escaping @Sendable () -> Void = {}) { self.onUnavailable = onUnavailable }
    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) {
        lock.lock(); defer { lock.unlock() }; self.callback = callback
    }
    func startDecode(withNumberOfCores numberOfCores: Int32) -> Int {
        VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) ? 0 : -1
    }
    func implementationName() -> String { "VideoToolbox HEVC hardware" }
    func release() -> Int {
        lock.lock(); defer { lock.unlock() }
        resetSession(); parameters.removeAll(); callback = nil; decoded = false
        return 0
    }
    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    func decode(
        _ encodedImage: RTCEncodedImage, missingFrames: Bool,
        codecSpecificInfo info: (any RTCCodecSpecificInfo)?, renderTimeMs: Int64
    ) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let units = Self.nalUnits(encodedImage.buffer) else { return -1 }
        var changed = false
        for unit in units {
            let type = Int((unit[unit.startIndex] >> 1) & 63)
            if (32...34).contains(type), parameters[type] != unit {
                parameters[type] = unit; changed = true
            }
        }
        if changed { resetSession() }
        let key = units.contains { (16...21).contains(Int(($0[$0.startIndex] >> 1) & 63)) }
        if missingFrames { needsKeyFrame = true }
        guard !needsKeyFrame || key else { return -1 }
        if session == nil {
            guard createSession() else { return -1 }
        }
        guard let session, let format, let callback else { return -1 }
        var payload = Data()
        for unit in units {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
            payload.append(unit)
        }
        guard payload.count <= 16 * 1024 * 1024 else { return -1 }
        var block: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: payload.count, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: payload.count, flags: 0,
                blockBufferOut: &block) == kCMBlockBufferNoErr, let block
        else { return -1 }
        let copy = payload.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count)
        }
        guard copy == kCMBlockBufferNoErr else { return -1 }
        var sample: CMSampleBuffer?
        var size = payload.count
        guard
            CMSampleBufferCreateReady(
                allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample
        else { return -1 }
        let result = HEVCDecodeResult(callback: callback)
        let timestamp = encodedImage.timeStamp
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            status, _, pixel, _, _ in
            guard status == noErr, let pixel else { result.finish(false); return }
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixel), rotation: ._0, timeStampNs: 0)
            frame.timeStamp = Int32(bitPattern: timestamp)
            result.deliver(frame)
            result.finish(true)
        }
        if status == noErr && result.succeeded {
            decoded = true; needsKeyFrame = false; return 0
        }
        needsKeyFrame = true
        return -1
    }

    private func resetSession() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil; needsKeyFrame = true
    }

    private func createSession() -> Bool {
        guard let vps = parameters[32], let sps = parameters[33], let pps = parameters[34] else { return false }
        var next: CMVideoFormatDescription?
        let status = vps.withUnsafeBytes { v in
            sps.withUnsafeBytes { s in
                pps.withUnsafeBytes { p in
                    let pointers = [
                        v.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        s.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        p.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ]
                    let sizes = [vps.count, sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: nil, parameterSetCount: 3, parameterSetPointers: pointers,
                        parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &next)
                }
            }
        }
        guard status == noErr, let next else { return false }
        let dimensions = CMVideoFormatDescriptionGetDimensions(next)
        guard dimensions.width > 0, dimensions.height > 0, dimensions.width <= 1920, dimensions.height <= 1080 else {
            return false
        }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        var created: VTDecompressionSession?
        guard
            VTDecompressionSessionCreate(
                allocator: nil, formatDescription: next,
                decoderSpecification: [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true]
                    as CFDictionary,
                imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                decompressionSessionOut: &created) == noErr, let created
        else { if !decoded { onUnavailable() }; return false }
        var hardware: CFTypeRef?
        guard
            VTSessionCopyProperty(
                created, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil,
                valueOut: &hardware) == noErr,
            hardware as? Bool == true
        else { VTDecompressionSessionInvalidate(created); if !decoded { onUnavailable() }; return false }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created; format = next
        return true
    }

    static func nalUnits(_ data: Data) -> [Data]? {
        guard !data.isEmpty, data.count <= 16 * 1024 * 1024 else { return nil }
        let bytes = [UInt8](data)
        var starts: [(Int, Int)] = [], index = 0
        while index + 3 <= bytes.count {
            if starts.count >= 4096 { return nil }
            if bytes[index] == 0 && bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 { starts.append((index, index + 3)); index += 3; continue }
                if index + 4 <= bytes.count && bytes[index + 2] == 0 && bytes[index + 3] == 1 {
                    starts.append((index, index + 4)); index += 4; continue
                }
            }
            index += 1
            if starts.count > 4096 { return nil }
        }
        guard starts.first?.0 == 0, starts.count <= 4096 else { return nil }
        var result: [Data] = []
        for i in starts.indices {
            let end = i + 1 < starts.count ? starts[i + 1].0 : bytes.count
            guard end - starts[i].1 >= 2 else { return nil }
            let unit = Data(bytes[starts[i].1..<end])
            let type = Int((unit[0] >> 1) & 63)
            guard unit[0] & 0x81 == 0, unit[1] & 0xf8 == 0, unit[1] & 7 != 0,
                !(32...34).contains(type) || unit.count <= 65536
            else { return nil }
            result.append(unit)
        }
        return result
    }
}

private final class HEVCDecodeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private let callback: RTCVideoDecoderCallback
    init(callback: @escaping RTCVideoDecoderCallback) { self.callback = callback }
    // DecodeFrame without asynchronous/temporal flags completes callbacks before
    // returning; the decoder lock serializes this callback with release().
    func deliver(_ frame: RTCVideoFrame) { callback(frame) }
    func finish(_ success: Bool) { lock.lock(); value = success; lock.unlock() }
    var succeeded: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
