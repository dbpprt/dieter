import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Every field and VideoToolbox operation is confined to CaptureRunner.stateQueue.
/// The compression callback transfers frame ownership back to that queue; it never
/// touches this state directly. Invalidation drains the compression session first.
final class CaptureEncoderSession {
    private let queue: DispatchQueue
    private let options: CaptureOptions
    private var configuration: StreamConfiguration
    private var output: VTCompressionOutputCallback?
    private(set) var encoder: VTCompressionSession?
    private(set) var transfer: VTPixelTransferSession?
    private(set) var pixelPool: CVPixelBufferPool?
    private(set) var encoderConfiguration = ""
    private(set) var ltrEnabled = false
    private let burstEnvelope = EncoderBurstEnvelope.configured
    private let traceRecovery =
        ProcessInfo.processInfo.environment["DIETER_TEST_CAPTURE_RECOVERY_DIAGNOSTICS"] == "1"
    init(queue: DispatchQueue, options: CaptureOptions) {
        self.queue = queue
        self.options = options
        configuration = StreamConfiguration(
            displayId: options.displayID, maxWidth: options.maxWidth,
            maxHeight: options.maxHeight, fps: options.fps, bitrateKbps: options.bitrateKbps,
            embeddedCursor: options.embeddedCursor)
    }
    func invalidate() {
        dispatchPrecondition(condition: .onQueue(queue))
        if let encoder {
            VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(encoder)
        }
        encoder = nil
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
        transfer = nil
        pixelPool = nil
        ltrEnabled = false
    }
    func create(
        width: Int, height: Int, configuration: StreamConfiguration,
        output: @escaping VTCompressionOutputCallback
    ) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        self.configuration = configuration
        self.output = output
        invalidate()
        do { try initializeEncoder(width: width, height: height) } catch {
            // LTR is optional. Older HEVC hardware keeps the existing encoder
            // mode if it cannot create Apple's low-latency encoder variant.
            if options.codec == "H265" && options.referenceRecovery {
                invalidate()
                do {
                    try initializeEncoder(width: width, height: height, lowLatencyHEVC: false)
                    return
                } catch {
                    throw CaptureError.hevcUnavailable(error.localizedDescription)
                }
            }
            if options.codec == "H265" { throw CaptureError.hevcUnavailable(error.localizedDescription) }
            throw error
        }
    }

    private func initializeEncoder(width: Int, height: Int, lowLatencyHEVC: Bool = true) throws {
        if options.codec == "H265"
            && (width > 1920 || height > 1080 || configuration.fps > 60
                || configuration.bitrateKbps > 40000)
        {
            throw CaptureError.invalidArgument("HEVC supports at most 1080p60/40000 kbps")
        }
        var session: VTCompressionSession?
        var spec: [String: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true,
        ]
        if options.codec == "H265" && (!options.referenceRecovery || !lowLatencyHEVC) {
            spec.removeValue(forKey: kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String)
        }
        let specification = spec as CFDictionary
        let attributes =
            [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ] as CFDictionary
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: options.codec == "H265" ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: specification,
            imageBufferAttributes: attributes,
            compressedDataAllocator: nil,
            outputCallback: output,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else { throw CaptureError.encoder(status) }
        encoder = session
        encoderConfiguration = ""
        ltrEnabled =
            options.referenceRecovery
            && VTSessionSetProperty(
                session, key: kVTCompressionPropertyKey_EnableLTR, value: kCFBooleanTrue) == noErr
        if options.referenceRecovery {
            writeDiagnostic("reference recovery codec=\(options.codec) enabled=\(ltrEnabled)")
        }
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
        transfer = nil
        pixelPool = nil
        let transferStatus = VTPixelTransferSessionCreate(
            allocator: nil, pixelTransferSessionOut: &transfer)
        guard transferStatus == noErr else { throw CaptureError.encoder(transferStatus) }
        let poolStatus = CVPixelBufferPoolCreate(
            nil, nil,
            [
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ] as CFDictionary, &pixelPool)
        guard poolStatus == kCVReturnSuccess else { throw CaptureError.encoder(poolStatus) }

        try set(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        try set(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        try set(
            session, kVTCompressionPropertyKey_ProfileLevel,
            options.codec == "H265"
                ? kVTProfileLevel_HEVC_Main_AutoLevel
                : (options.profile == "high"
                    ? kVTProfileLevel_H264_High_AutoLevel
                    : kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel))
        // HEVC hardware does not expose MaxFrameDelayCount. Frame reordering is
        // disabled, and the existing single frame credit bounds encoder work.
        try set(session, kVTCompressionPropertyKey_ExpectedFrameRate, configuration.fps as CFNumber)
        try configureRate(session, kbps: configuration.bitrateKbps)
        let speedStatus = VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            value: kCFBooleanTrue)
        encoderConfiguration +=
            "; speedPriority=\(speedStatus == noErr ? "accepted" : "rejected(\(speedStatus))")"
        writeDiagnostic("encoder configuration codec=\(options.codec) \(encoderConfiguration)")
        try set(
            session, kVTCompressionPropertyKey_MaxKeyFrameInterval, (configuration.fps * 10) as CFNumber)
        try set(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 10 as CFNumber)
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else { throw CaptureError.encoder(prepareStatus) }
    }

    func set(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else {
            throw NSError(
                domain: "DieterCapture", code: Int(status),
                userInfo: [
                    NSLocalizedDescriptionKey: "VideoToolbox property \(key) failed with status \(status)"
                ])
        }
    }

    func configureRate(_ session: VTCompressionSession, kbps: Int) throws {
        try set(session, kVTCompressionPropertyKey_AverageBitRate, (kbps * 1000) as CFNumber)
        let burst = burstEnvelope.apply(kbps: kbps) {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: $0)
        }
        let suffix = encoderConfiguration.split(separator: ";").last.map(String.init)
        encoderConfiguration = "hardware=required; realtime=accepted; reorder=disabled; \(burst)"
        if let suffix, suffix.contains("speedPriority=") { encoderConfiguration += ";\(suffix)" }
    }

}
