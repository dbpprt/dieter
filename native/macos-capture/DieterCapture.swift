import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import ScreenCaptureKit
import VideoToolbox

private let streamMagic = Data("DTH2".utf8)

struct CaptureOptions {
    var displayID = "primary"
    var fps = 60
    var bitrateKbps = 12_000
    var maxWidth = 3_840
    var maxHeight = 2_160

    var eventFD: Int32 = -1
    var profile = "high"
    var embeddedCursor = false
    var allowInput = false
    var synthetic = false
    var frameCredits = false
    var multiplex = false
    var streamID: UInt64 = 0

    static func parse() throws -> CaptureOptions {
        var value = CaptureOptions()
        var arguments = Array(CommandLine.arguments.dropFirst())
        while !arguments.isEmpty {
            let name = arguments.removeFirst()
            guard !arguments.isEmpty else { throw CaptureError.invalidArgument(name) }
            let raw = arguments.removeFirst()
            switch name {
            case "--display-id": value.displayID = raw
            case "--fps": value.fps = try integer(raw, name: name, range: 1...60)
            case "--bitrate-kbps": value.bitrateKbps = try integer(raw, name: name, range: 100...100_000)
            case "--max-width": value.maxWidth = try integer(raw, name: name, range: 320...16_384)
            case "--max-height": value.maxHeight = try integer(raw, name: name, range: 180...16_384)
            case "--event-fd": value.eventFD = Int32(try integer(raw, name: name, range: 3...3))
            case "--profile": value.profile = raw == "baseline" ? "baseline" : "high"
            case "--embedded-cursor": value.embeddedCursor = raw == "true"
            case "--allow-input": value.allowInput = raw == "true"
            case "--synthetic": value.synthetic = raw == "true"
            case "--frame-credits": value.frameCredits = raw == "true"
            case "--multiplex": value.multiplex = raw == "true"
            default: throw CaptureError.invalidArgument(name)
            }
        }
        return value
    }

    private static func integer(_ raw: String, name: String, range: ClosedRange<Int>) throws -> Int {
        guard let value = Int(raw), range.contains(value) else {
            throw CaptureError.invalidArgument(name)
        }
        return value
    }
}

enum CaptureError: LocalizedError {
    case invalidArgument(String)
    case noDisplay
    case encoder(OSStatus)
    case invalidFrame

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let name): "Invalid or missing value for \(name)"
        case .noDisplay: "The selected display is not available"
        case .encoder(let status): "VideoToolbox failed with status \(status)"
        case .invalidFrame: "ScreenCaptureKit produced an invalid frame"
        }
    }
}

private final class FrameContext {
    let runner: CaptureRunner
    let capturedAtNanoseconds: Int64
    let encodeStartedAt: UInt64
    let generation: UInt64
    init(
        runner: CaptureRunner, capturedAtNanoseconds: Int64, encodeStartedAt: UInt64, generation: UInt64
    ) {
        self.runner = runner
        self.generation = generation
        self.capturedAtNanoseconds = capturedAtNanoseconds
        self.encodeStartedAt = encodeStartedAt
    }
}

struct CapturedFrame {
    let sampleBuffer: CMSampleBuffer
    let capturedAtNanoseconds: Int64
}

final class CaptureRunner: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let options: CaptureOptions
    private let stateQueue = DispatchQueue(
        label: "com.dbpprt.dieter.capture.state", qos: .userInteractive)
    private let outputQueue = DispatchQueue(
        label: "com.dbpprt.dieter.capture.output", qos: .userInteractive)
    private let stopSemaphore = DispatchSemaphore(value: 0)
    private let stoppedGroup = DispatchGroup()
    private let stopLock = NSLock()

    private var stream: SCStream?
    private var sharedDisplay: CGDirectDisplayID?
    private let mailboxLock = NSLock()
    private var mailbox: CapturedFrame?
    private var mailboxScheduled = false
    private var transfer: VTPixelTransferSession?
    private var pixelPool: CVPixelBufferPool?
    private var lastSharedCapture: Int64 = 0
    private var encoder: VTCompressionSession?
    private var encoding = false
    // One encoded frame may be in the pipe/transport. Capture keeps replacing
    // the raw pending surface until the daemon returns this exact frame credit.
    private var outstandingFrame: UInt64?
    private var outputBusy = false
    private var pendingFrame: CapturedFrame?
    private var forceKeyFrame = true
    private var stopped = false
    private var inputInjector: InputInjector?
    private let inputQueue = DispatchQueue(label: "com.dbpprt.dieter.capture.input", qos: .userInteractive)
    private var configuration: StreamConfiguration
    private var events: EventWriter
    private var generation: UInt64 = 1
    private var frameID: UInt64 = 0
    private var dropped: UInt64 = 0
    private var outputWidth = 0
    private var outputHeight = 0
    private var selectedDisplaySnapshot: NativeDisplay?
    private var selectedDisplayID: CGDirectDisplayID = 0
    private var paused = false
    private var lastFrame: CapturedFrame?
    private var lastRefresh: UInt64 = 0
    private var lastHeartbeat = DispatchTime.now().uptimeNanoseconds
    private var timers: [DispatchSourceTimer] = []
    private let configurationGate = ConfigurationGate()
    private var signals: [DispatchSourceSignal] = []
    private var actualEmbeddedCursor = false
    private var forceEmbeddedCursor = false  // stateQueue
    private var cursorFallbackPending = false
    private var cursorUnavailableSamples = 0
    private var lastCursorGeneration: UInt64 = 0
    private var lastCursorShape = ""
    private var lastCursorPoint = CGPoint(x: -1, y: -1)
    private var lastCursorSentAt: UInt64 = 0
    private var syntheticTimer: DispatchSourceTimer?
    private var syntheticCounter: UInt64 = 0
    private let syntheticStarted = DispatchTime.now().uptimeNanoseconds
    private let syntheticIdleCycle = ProcessInfo.processInfo.environment["DIETER_TEST_CAPTURE_IDLE_CYCLE"] == "1"

    init(options: CaptureOptions) {
        self.options = options
        stoppedGroup.enter()
        self.configuration = StreamConfiguration(
            displayId: options.displayID, maxWidth: options.maxWidth, maxHeight: options.maxHeight, fps: options.fps,
            bitrateKbps: options.bitrateKbps, embeddedCursor: options.embeddedCursor)
        self.events = EventWriter(fd: options.eventFD, streamID: options.streamID)
    }

    func start() async throws {
        try await configurationGate.acquire()
        do {
            try await startCapture()
            await configurationGate.release()
        } catch {
            await configurationGate.release()
            throw error
        }
    }

    private func startCapture() async throws {
        signal(SIGPIPE, SIG_IGN)
        _ = fcntl(STDOUT_FILENO, F_SETFL, fcntl(STDOUT_FILENO, F_GETFL) | O_NONBLOCK)
        if !options.multiplex {
            guard MediaWriter.shared.write(streamMagic) else { throw CaptureError.invalidFrame }
        }
        try await startStream()
        startControlReader()
        if !options.multiplex {
            let watchdog = DispatchSource.makeTimerSource(queue: inputQueue)
            watchdog.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
            watchdog.setEventHandler { [weak self] in
                guard let self else { return }
                if DispatchTime.now().uptimeNanoseconds - self.lastHeartbeat > 3_000_000_000 {
                    self.inputInjector?.releaseAll()
                    self.stop()
                }
            }
            watchdog.resume()
            registerTimer(watchdog)
        }
        let cursor = DispatchSource.makeTimerSource(queue: .main)
        cursor.schedule(deadline: .now(), repeating: .milliseconds(33))
        cursor.setEventHandler { [weak self] in self?.sendCursor() }
        cursor.resume()
        registerTimer(cursor)
        for value in options.multiplex ? [] : [SIGTERM, SIGINT] {
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .global())
            source.setEventHandler { [weak self] in self?.stop() }
            source.resume(); signals.append(source)
        }
        let topology = DispatchSource.makeTimerSource(queue: stateQueue)
        topology.schedule(deadline: .now() + 2, repeating: 2)
        topology.setEventHandler { [weak self] in
            guard let self, !self.options.synthetic, !self.paused else { return }
            let id = self.selectedDisplayID
            let current = nativeDisplays().first { $0.id == String(id) }
            let rect = self.inputQueue.sync { self.inputInjector?.bounds }
            if current == nil || current != self.selectedDisplaySnapshot || rect != CGDisplayBounds(id)
                || (self.configuration.displayId == "primary" && CGMainDisplayID() != id)
            {
                self.paused = true
                Task { do { try await self.reconfigure(nil, force: true) } catch { self.stop() } }
            }
        }
        topology.resume(); registerTimer(topology)
    }

    private func startStream() async throws {
        let config = stateQueue.sync { configuration }
        try config.validate()
        if options.synthetic {
            let size = scaledSize(width: 1920, height: 1080)
            try stateQueue.sync {
                outputWidth = size.width; outputHeight = size.height
                try createEncoder(width: size.width, height: size.height)
            }
            inputQueue.sync {
                inputInjector = InputInjector(bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), dryRun: true)
                inputInjector?.update(bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), generation: generation)
            }
            emitState()
            return
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = selectedDisplay(content.displays) else { throw CaptureError.noDisplay }
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let size = scaledSize(width: mode?.pixelWidth ?? display.width, height: mode?.pixelHeight ?? display.height)
        try stateQueue.sync {
            selectedDisplayID = display.displayID
            selectedDisplaySnapshot = nativeDisplays().first { $0.id == String(display.displayID) }
            outputWidth = size.width; outputHeight = size.height
            try createEncoder(width: size.width, height: size.height)
        }
        inputQueue.sync {
            if inputInjector == nil {
                inputInjector = InputInjector(bounds: CGDisplayBounds(display.displayID))
            }
            if let inputInjector {
                SharedInputAuthority.shared.update(
                    inputInjector, bounds: CGDisplayBounds(display.displayID), generation: generation)
            }
        }
        if options.multiplex {
            sharedDisplay = display.displayID
            try await SharedDisplayPool.shared.add(
                display: display, id: options.streamID,
                width: size.width, height: size.height, fps: config.fps, cursor: config.embeddedCursor,
                receive: { [weak self] frame in self?.receiveShared(frame) },
                cursorChanged: { [weak self] embedded in
                    guard let self else { return }
                    self.stateQueue.async {
                        self.actualEmbeddedCursor = embedded
                        DispatchQueue.global().async { self.emitState() }
                    }
                },
                failed: { [weak self] error in
                    guard let self else { return }
                    _ = self.events.send(NativeEvent(error: error.localizedDescription))
                    self.stop()
                })
            if isStopped {
                await SharedDisplayPool.shared.remove(display: display.displayID, id: options.streamID)
                throw CaptureError.invalidArgument("capture stopped")
            }
            stateQueue.sync { paused = false }
            emitState()
            return
        }
        let native = streamConfiguration(config, size.width, size.height)
        let stream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: []), configuration: native, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: stateQueue)
        stateQueue.sync {
            self.stream = stream; self.paused = false
        }
        try await stream.startCapture()
        if isStopped { try? await stream.stopCapture(); throw CaptureError.invalidArgument("capture stopped") }
        emitState()
    }

    private func streamConfiguration(_ config: StreamConfiguration, _ width: Int, _ height: Int)
        -> SCStreamConfiguration
    {
        let value = SCStreamConfiguration()
        value.width = width; value.height = height
        value.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        value.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        value.queueDepth = 3; value.showsCursor = config.embeddedCursor
        value.capturesAudio = false; value.scalesToFit = true
        value.colorSpaceName = CGColorSpace.sRGB
        return value
    }

    private func reconfigure(_ requested: StreamConfiguration?, force: Bool = false, embedCursor: Bool = false)
        async throws
    {
        try await configurationGate.acquire()
        do {
            guard !isStopped else { throw CaptureError.invalidArgument("capture stopped") }
            var config = requested ?? stateQueue.sync { configuration }
            let fallback = stateQueue.sync {
                if embedCursor { forceEmbeddedCursor = true }
                return forceEmbeddedCursor
            }
            if fallback { config.embeddedCursor = true }
            try await applyConfiguration(config, force: force)
            await configurationGate.release()
        } catch {
            await configurationGate.release()
            throw error
        }
    }

    private func applyConfiguration(_ config: StreamConfiguration, force: Bool) async throws {
        try config.validate()
        let old = stateQueue.sync { configuration }
        if !force && old == config { return }
        let reset =
            force || old.displayId != config.displayId || old.maxWidth != config.maxWidth
            || old.maxHeight != config.maxHeight
        if reset {
            let oldStream = stateQueue.sync { () -> SCStream? in
                paused = true; pendingFrame = nil; lastFrame = nil; return stream
            }
            try await oldStream?.stopCapture()
            if let sharedDisplay {
                await SharedDisplayPool.shared.remove(display: sharedDisplay, id: options.streamID)
                self.sharedDisplay = nil
            }
            stateQueue.sync {
                if let encoder {
                    VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid);
                    VTCompressionSessionInvalidate(encoder)
                }
                encoder = nil; encoding = false; stream = nil
                configuration = config; generation += 1; forceKeyFrame = true
                syntheticTimer?.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / config.fps))
            }
            try await startStream()
            stateQueue.sync { paused = false }
        } else {
            let values = stateQueue.sync { (stream, outputWidth, outputHeight) }
            if let stream = values.0, old.fps != config.fps || old.embeddedCursor != config.embeddedCursor {
                try await stream.updateConfiguration(streamConfiguration(config, values.1, values.2))
            }
            if let sharedDisplay {
                try await SharedDisplayPool.shared.update(
                    display: sharedDisplay, id: options.streamID,
                    width: values.1, height: values.2, fps: config.fps, cursor: config.embeddedCursor)
            }
            try stateQueue.sync {
                configuration = config
                syntheticTimer?.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / config.fps))
                if let encoder {
                    try set(encoder, kVTCompressionPropertyKey_AverageBitRate, (config.bitrateKbps * 1000) as CFNumber)
                    try set(encoder, kVTCompressionPropertyKey_ExpectedFrameRate, config.fps as CFNumber)
                    _ = VTSessionSetProperty(
                        encoder, key: kVTCompressionPropertyKey_DataRateLimits,
                        value: [config.bitrateKbps * 125, 1] as CFArray)
                }
                // VideoToolbox applies rate changes to subsequent frames. A
                // bitrate recovery must not inject another large IDR burst.
            }
            emitState()
        }
    }

    private func emitState() {
        let state = stateQueue.sync {
            NativeState(
                width: outputWidth, height: outputHeight, fps: configuration.fps,
                bitrateKbps: configuration.bitrateKbps,
                displayId: options.synthetic ? "synthetic" : String(selectedDisplayID), displayGeneration: generation,
                encoder: options.profile == "high"
                    ? "VideoToolbox H.264 High / low latency" : "VideoToolbox H.264 Baseline / low latency",
                embeddedCursor: options.multiplex && !options.synthetic
                    ? actualEmbeddedCursor : configuration.embeddedCursor)
        }
        if !events.send(NativeEvent(state: state)) { stop() }
    }

    func wait() { stopSemaphore.wait() }

    func stopAndWait() async {
        stop()
        await withCheckedContinuation { continuation in
            stoppedGroup.notify(queue: .global()) { continuation.resume() }
        }
    }

    private var isStopped: Bool {
        stopLock.lock(); defer { stopLock.unlock() }; return stopped
    }

    private func registerTimer(_ timer: DispatchSourceTimer) {
        stopLock.lock()
        if stopped { timer.cancel() } else { timers.append(timer) }
        stopLock.unlock()
    }

    func stop() {
        stopLock.lock()
        if stopped {
            stopLock.unlock()
            return
        }
        stopped = true
        let stoppedTimers = timers
        timers.removeAll()
        stopLock.unlock()
        for timer in stoppedTimers { timer.cancel() }
        if options.multiplex { _ = events.send(NativeEvent(error: "native capture rendition stopped")) }
        // Teardown owns the runner until callbacks and shared capture detach finish.
        inputQueue.async { [self] in
            if self.options.multiplex {
                SharedInputAuthority.shared.remove(self.inputInjector)
            } else {
                self.inputInjector?.releaseAll()
            }
            Task {
                await self.configurationGate.shutdown()
                let stream = self.stateQueue.sync { () -> SCStream? in
                    if let encoder = self.encoder {
                        VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
                        VTCompressionSessionInvalidate(encoder)
                        self.encoder = nil
                    }
                    if let transfer = self.transfer { VTPixelTransferSessionInvalidate(transfer) }
                    self.transfer = nil
                    self.pixelPool = nil
                    let stream = self.stream
                    self.stream = nil
                    return stream
                }
                try? await stream?.stopCapture()
                if let sharedDisplay = self.sharedDisplay {
                    await SharedDisplayPool.shared.remove(display: sharedDisplay, id: self.options.streamID)
                }
                self.stopSemaphore.signal()
                self.stoppedGroup.leave()
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        writeDiagnostic("capture stopped: \(error.localizedDescription)")
        stop()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard stream === self.stream, !paused, outputType == .screen, CMSampleBufferIsValid(sampleBuffer),
            CMSampleBufferGetImageBuffer(sampleBuffer) != nil
        else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus), status != .complete && status != .started
        {
            return
        }

        let frame = CapturedFrame(
            sampleBuffer: sampleBuffer,
            capturedAtNanoseconds: Int64(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds * 1_000_000_000))
        offer(frame)
    }

    // Coalesce before dispatching: a blocked encoder retains at most one raw surface.
    private func receiveShared(_ frame: CapturedFrame) {
        mailboxLock.lock()
        mailbox = frame
        if mailboxScheduled {
            mailboxLock.unlock()
            return
        }
        mailboxScheduled = true
        mailboxLock.unlock()
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.mailboxLock.lock()
            let next = self.mailbox
            self.mailbox = nil
            self.mailboxScheduled = false
            self.mailboxLock.unlock()
            guard !self.isStopped, !self.paused, let next else { return }
            let interval = Int64(1_000_000_000 / max(1, self.configuration.fps))
            guard next.capturedAtNanoseconds - self.lastSharedCapture >= interval * 9 / 10 else { return }
            self.lastSharedCapture = next.capturedAtNanoseconds
            self.offer(next)
        }
    }

    private func offer(_ frame: CapturedFrame) {
        lastFrame = frame
        if pendingFrame != nil { dropped += 1 }
        pendingFrame = frame
        admitPendingFrame()
    }

    private func admitPendingFrame() {
        guard !paused, !encoding, !outputBusy, outstandingFrame == nil, let next = pendingFrame else { return }
        pendingFrame = nil
        encode(next)
    }

    private func selectedDisplay(_ displays: [SCDisplay]) -> SCDisplay? {
        if configuration.displayId == "" || configuration.displayId == "primary" {
            return displays.first(where: { CGDisplayIsMain($0.displayID) != 0 }) ?? displays.first
        }
        guard let displayID = CGDirectDisplayID(configuration.displayId) else { return nil }
        return displays.first(where: { $0.displayID == displayID })
    }

    private func scaledSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let scale = min(
            1.0, min(Double(configuration.maxWidth) / Double(width), Double(configuration.maxHeight) / Double(height))
        )
        let scaledWidth = max(2, Int(Double(width) * scale)) & ~1
        let scaledHeight = max(2, Int(Double(height) * scale)) & ~1
        return (scaledWidth, scaledHeight)
    }

    private func createEncoder(width: Int, height: Int) throws {
        var session: VTCompressionSession?
        let spec: [String: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true,
        ]
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
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification,
            imageBufferAttributes: attributes,
            compressedDataAllocator: nil,
            outputCallback: { _, sourceFrameRefcon, status, flags, sampleBuffer in
                guard let sourceFrameRefcon else { return }
                // Each in-flight frame owns its runner. A session can disappear
                // while VideoToolbox is finishing on its private callback queue.
                let context = Unmanaged<FrameContext>.fromOpaque(sourceFrameRefcon).takeRetainedValue()
                let runner = context.runner
                runner.stateQueue.async {
                    runner.encoded(context: context, status: status, flags: flags, sampleBuffer: sampleBuffer)
                }
            },
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else { throw CaptureError.encoder(status) }
        encoder = session
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
            options.profile == "high"
                ? kVTProfileLevel_H264_High_AutoLevel : kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel)
        try set(session, kVTCompressionPropertyKey_ExpectedFrameRate, configuration.fps as CFNumber)
        try set(
            session, kVTCompressionPropertyKey_AverageBitRate, (configuration.bitrateKbps * 1_000) as CFNumber)
        try set(
            session, kVTCompressionPropertyKey_DataRateLimits, [configuration.bitrateKbps * 125, 1] as CFArray)
        _ = VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        try set(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, (configuration.fps * 10) as CFNumber)
        try set(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 10 as CFNumber)
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else { throw CaptureError.encoder(prepareStatus) }
    }

    private func set(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else { throw CaptureError.encoder(status) }
    }

    private func encode(_ frame: CapturedFrame) {
        guard !paused, let encoder, let imageBuffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer) else {
            return
        }
        var outputBuffer = imageBuffer
        if CVPixelBufferGetWidth(imageBuffer) != outputWidth
            || CVPixelBufferGetHeight(imageBuffer) != outputHeight
        {
            var scaled: CVPixelBuffer?
            guard let pixelPool, let transfer,
                CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                    nil, pixelPool,
                    [kCVPixelBufferPoolAllocationThresholdKey as String: 3] as CFDictionary, &scaled)
                    == kCVReturnSuccess,
                let scaled,
                VTPixelTransferSessionTransferImage(transfer, from: imageBuffer, to: scaled) == noErr
            else {
                dropped += 1
                return
            }
            outputBuffer = scaled
        }
        encoding = true
        let context = FrameContext(
            runner: self, capturedAtNanoseconds: frame.capturedAtNanoseconds,
            encodeStartedAt: DispatchTime.now().uptimeNanoseconds, generation: generation
        )
        var properties: CFDictionary?
        if forceKeyFrame {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            forceKeyFrame = false
        }
        let status = VTCompressionSessionEncodeFrame(
            encoder,
            imageBuffer: outputBuffer,
            presentationTimeStamp: CMTime(value: frame.capturedAtNanoseconds, timescale: 1_000_000_000),
            duration: CMTime(value: 1, timescale: CMTimeScale(configuration.fps)),
            frameProperties: properties,
            sourceFrameRefcon: Unmanaged.passRetained(context).toOpaque(),
            infoFlagsOut: nil
        )
        if status != noErr {
            Unmanaged<FrameContext>.fromOpaque(Unmanaged.passUnretained(context).toOpaque()).release()
            encodingCompleted()
            writeDiagnostic("encode failed: \(status)")
        }
    }

    private func encoded(
        context: FrameContext?,
        status: OSStatus,
        flags: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBuffer?
    ) {
        guard !isStopped, let context, context.generation == generation else { return }
        defer { encodingCompleted() }
        guard status == noErr, !flags.contains(.frameDropped), let sampleBuffer else {
            if status != noErr { writeDiagnostic("encode callback failed: \(status)") }
            return
        }
        do {
            let keyFrame = isKeyFrame(sampleBuffer)
            let accessUnit = try annexB(sampleBuffer, includeParameterSets: keyFrame)
            let encodeDuration = DispatchTime.now().uptimeNanoseconds - context.encodeStartedAt
            writeFrame(
                accessUnit,
                keyFrame: keyFrame,
                captureNanoseconds: context.capturedAtNanoseconds,
                encodeNanoseconds: encodeDuration
            )
        } catch {
            writeDiagnostic("encode output failed: \(error.localizedDescription)")
        }
    }

    private func encodingCompleted() {
        encoding = false
        admitPendingFrame()
    }

    private func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
            let first = attachments.first
        else { return false }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    private func annexB(_ sampleBuffer: CMSampleBuffer, includeParameterSets: Bool) throws -> Data {
        var output = Data()
        let startCode: [UInt8] = [0, 0, 0, 1]
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw CaptureError.invalidFrame
        }
        var count = 0
        var headerLength: Int32 = 0
        let queryStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil,
            parameterSetSizeOut: nil, parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &headerLength
        )
        guard queryStatus == noErr else { throw CaptureError.encoder(queryStatus) }
        guard (1...4).contains(headerLength) else { throw CaptureError.invalidFrame }
        if includeParameterSets {
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let parameterStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                )
                guard parameterStatus == noErr, let pointer else {
                    throw CaptureError.encoder(parameterStatus)
                }
                output.append(contentsOf: startCode)
                output.append(pointer, count: size)
            }
        }

        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw CaptureError.invalidFrame
        }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let dataStatus = CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength, dataPointerOut: &dataPointer
        )
        guard dataStatus == kCMBlockBufferNoErr, let dataPointer else {
            throw CaptureError.encoder(dataStatus)
        }
        let bytes = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        let lengthBytes = Int(headerLength)
        while offset + lengthBytes <= totalLength {
            var length = 0
            for index in 0..<lengthBytes { length = length << 8 | Int(bytes[offset + index]) }
            offset += lengthBytes
            guard length > 0, offset + length <= totalLength else { throw CaptureError.invalidFrame }
            output.append(contentsOf: startCode)
            output.append(bytes + offset, count: length)
            offset += length
        }
        guard offset == totalLength else { throw CaptureError.invalidFrame }
        return output
    }

    private func writeFrame(
        _ payload: Data,
        keyFrame: Bool,
        captureNanoseconds: Int64,
        encodeNanoseconds: UInt64
    ) {
        frameID += 1
        var header = Data()
        if options.multiplex { header.appendBigEndian(options.streamID) }
        header.appendBigEndian(UInt32(payload.count))
        header.appendBigEndian(UInt32(keyFrame ? 1 : 0))
        header.appendBigEndian(frameID)
        header.appendBigEndian(generation)
        header.appendBigEndian(UInt64(bitPattern: captureNanoseconds))
        header.appendBigEndian(encodeNanoseconds)
        let now = Int64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * 1_000_000_000)
        header.appendBigEndian(UInt64(max(0, now - captureNanoseconds)))
        header.appendBigEndian(UInt32(outputWidth))
        header.appendBigEndian(UInt32(outputHeight))
        header.appendBigEndian(dropped)
        if options.frameCredits { outstandingFrame = frameID }
        outputBusy = true
        let data = header + payload
        outputQueue.async { [self] in
            let success = MediaWriter.shared.write(data)
            stateQueue.async { [self] in
                outputBusy = false
                if success { admitPendingFrame() } else { stop() }
            }
        }
    }

    private func startControlReader() {
        if options.synthetic {
            let timer = DispatchSource.makeTimerSource(queue: stateQueue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / configuration.fps))
            syntheticTimer = timer
            timer.setEventHandler { [weak self] in self?.syntheticFrame() }
            timer.resume(); registerTimer(timer)
        }
        if options.multiplex { return }
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            var pending = Data()
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
                if count <= 0 { break }
                pending.append(contentsOf: bytes.prefix(count))
                while let end = pending.firstIndex(of: 10) {
                    let data = pending.prefix(upTo: end)
                    if data.count > 16384 { self.stop(); return }
                    pending.removeSubrange(...end)
                    guard let command = try? decoder.decode(NativeCommand.self, from: data), command.version == 2 else {
                        self.stop(); return
                    }
                    let done = DispatchSemaphore(value: 0)
                    Task {
                        var failure: String?
                        do {
                            try await self.handle(command)
                        } catch { failure = error.localizedDescription }
                        if !self.events.send(NativeEvent(ack: command.id, error: failure)) { self.stop() }
                        done.signal()
                    }
                    done.wait()
                }
                if pending.count > 16384 { break }
            }
            self.inputQueue.sync { self.inputInjector?.releaseAll() }
            self.stop()
        }
    }

    func handle(_ command: NativeCommand) async throws {
        switch command.kind {
        case "heartbeat":
            self.inputQueue.sync { self.lastHeartbeat = DispatchTime.now().uptimeNanoseconds }
        case "input":
            guard let input = command.input, self.options.allowInput || input.kind == "release_all"
            else { throw CaptureError.invalidArgument("control not granted") }
            try self.inputQueue.sync {
                if let injector = self.inputInjector {
                    if self.options.multiplex {
                        try SharedInputAuthority.shared.handle(input, injector: injector)
                    } else {
                        try injector.handle(input)
                    }
                }
            }
        case "configure":
            guard let config = command.configuration else {
                throw CaptureError.invalidArgument("configuration")
            }
            try await self.reconfigure(config)
        case "frame_consumed":
            self.stateQueue.sync {
                if let frameID = command.frameId, self.outstandingFrame == frameID {
                    self.outstandingFrame = nil
                    self.admitPendingFrame()
                }
            }
        case "refresh": self.stateQueue.sync { self.refresh() }
        case "stop":
            self.inputQueue.sync { self.inputInjector?.releaseAll() }
            self.stop()
        default: throw CaptureError.invalidArgument("command kind")
        }
    }

    private func refresh() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastRefresh > 200_000_000 else { return }
        lastRefresh = now
        forceKeyFrame = true
        if let lastFrame {
            // A refresh is a new presentation of retained pixels, not an old RTP time.
            let time = Int64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * 1_000_000_000)
            offer(CapturedFrame(sampleBuffer: lastFrame.sampleBuffer, capturedAtNanoseconds: time))
        }
    }

    private func syntheticFrame() {
        guard !paused else { return }
        if syntheticIdleCycle {
            let elapsed = (DispatchTime.now().uptimeNanoseconds - syntheticStarted) / 1_000_000_000
            if (8..<13).contains(elapsed % 18) { return }
        }
        var pixel: CVPixelBuffer?
        guard
            CVPixelBufferCreate(
                nil, outputWidth, outputHeight, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pixel) == kCVReturnSuccess,
            let pixel
        else { return }
        CVPixelBufferLockBaseAddress(pixel, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(pixel) {
            if let base = CVPixelBufferGetBaseAddressOfPlane(pixel, plane) {
                memset(
                    base, plane == 0 ? Int32(32 + syntheticCounter % 160) : 128,
                    CVPixelBufferGetBytesPerRowOfPlane(pixel, plane) * CVPixelBufferGetHeightOfPlane(pixel, plane))
            }
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        syntheticCounter += 1
        var format: CMVideoFormatDescription?
        guard
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format) == noErr, let format
        else { return }
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(configuration.fps)), presentationTimeStamp: pts,
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: nil, imageBuffer: pixel, formatDescription: format, sampleTiming: &timing,
                sampleBufferOut: &sample) == noErr, let sample
        else { return }
        let frame = CapturedFrame(sampleBuffer: sample, capturedAtNanoseconds: Int64(pts.seconds * 1_000_000_000))
        offer(frame)
    }

    private func cursorPNG(_ cursor: NSCursor) -> Data? {
        let size = cursor.image.size
        guard size.width > 0, size.height > 0, size.width <= 256, size.height <= 256 else { return nil }
        // System cursors include oversized representations (often 10x). Draw
        // the logical cursor at 2x rather than serializing its largest TIFF rep.
        let width = min(256, Int(ceil(size.width * 2)))
        let height = min(256, Int(ceil(size.height * 2)))
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        cursor.image.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero,
            operation: .copy, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]), png.count <= 262144 else { return nil }
        return png
    }

    private func sendCursor() {
        let config = stateQueue.sync {
            (
                options.multiplex && !options.synthetic
                    ? actualEmbeddedCursor : configuration.embeddedCursor,
                generation, paused
            )
        }
        guard !config.0, !config.2 else { return }
        guard let cursor = NSCursor.currentSystem, let png = cursorPNG(cursor) else {
            cursorUnavailableSamples += 1
            if cursorUnavailableSamples >= 3, !cursorFallbackPending {
                cursorFallbackPending = true
                Task { do { try await self.reconfigure(nil, embedCursor: true) } catch { self.stop() } }
            }
            return
        }
        cursorUnavailableSamples = 0
        let shape = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let point = CGEvent(source: nil)?.location ?? .zero
        let now = DispatchTime.now().uptimeNanoseconds
        guard
            config.1 != lastCursorGeneration || shape != lastCursorShape || point != lastCursorPoint
                || now - lastCursorSentAt > 1_000_000_000
        else {
            return
        }
        let state = inputQueue.sync { (inputInjector?.bounds ?? .zero, inputInjector?.lastOrdinal ?? 0) }
        guard state.0.width > 0, state.0.height > 0 else { return }
        let x = Int32(max(0, min(1, (point.x - state.0.minX) / state.0.width)) * 1_000_000)
        let y = Int32(max(0, min(1, (point.y - state.0.minY) / state.0.height)) * 1_000_000)
        let value = NativeCursor(
            shapeId: shape, png: shape == lastCursorShape ? nil : png, hotspotX: cursor.hotSpot.x,
            hotspotY: cursor.hotSpot.y, width: cursor.image.size.width, height: cursor.image.size.height,
            normalizedX: x, normalizedY: y, visible: state.0.contains(point), displayGeneration: config.1,
            lastInputOrdinal: state.1)
        lastCursorGeneration = config.1
        lastCursorShape = shape; lastCursorPoint = point; lastCursorSentAt = now
        if !events.send(NativeEvent(cursor: value)) { stop() }
    }

}

extension Data {
    fileprivate mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}

private func writeDiagnostic(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func hardwareEncoderAvailable() -> Bool {
    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(
        allocator: kCFAllocatorDefault, width: 640, height: 360,
        codecType: kCMVideoCodecType_H264,
        encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
            as CFDictionary,
        imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
        compressionSessionOut: &session)
    if let session { VTCompressionSessionInvalidate(session) }
    return status == noErr
}

#if !DIETER_CAPTURE_TEST
    @main
    private struct DieterCapture {
        static func main() async {
            do {
                if CommandLine.arguments.dropFirst().contains("--capabilities") {
                    let synthetic = CommandLine.arguments.contains("--synthetic")
                    let displays =
                        synthetic
                        ? [
                            NativeDisplay(
                                id: "synthetic", name: "Synthetic display", logicalWidth: 1920, logicalHeight: 1080,
                                physicalWidth: 1920, physicalHeight: 1080, scale: 1, rotation: 0, primary: true,
                                originX: 0, originY: 0, refreshRate: 60)
                        ] : nativeDisplays()
                    let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
                    let displayData = try encoder.encode(displays)
                    let displayJSON = try JSONSerialization.jsonObject(with: displayData)
                    let granted = synthetic || CGPreflightScreenCaptureAccess()
                    let value: [String: Any] = [
                        "platform": "darwin", "helper_version": "native-v2",
                        "graphical_session_active": synthetic || !displays.isEmpty,
                        "capture_permission": granted ? "granted" : "denied",
                        "control_permission": (synthetic || CGPreflightPostEventAccess()) ? "granted" : "denied",
                        "displays": displayJSON, "codecs": ["H264"],
                        "hardware_encoder_available": hardwareEncoderAvailable(), "control_supported": true,
                        "adaptive_supported": true, "cursor_supported": true, "input_protocol_version": 2,
                        "max_fps": 60, "encoder": "VideoToolbox H.264",
                    ]
                    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value))
                    return
                }
                if CommandLine.arguments.dropFirst().contains("--check-control") {
                    guard CGPreflightPostEventAccess() else {
                        throw NSError(
                            domain: "DieterCapture", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Accessibility event-posting permission is denied"])
                    }
                    return
                }
                if CommandLine.arguments.dropFirst().contains("--request-control") {
                    guard CGRequestPostEventAccess() else {
                        throw NSError(
                            domain: "DieterCapture", code: 3,
                            userInfo: [
                                NSLocalizedDescriptionKey: "Accessibility event-posting permission was not granted"
                            ])
                    }
                    return
                }
                let options = try CaptureOptions.parse()
                if options.multiplex {
                    let service = NativeCaptureService(options: options)
                    try await service.run()
                    return
                }
                let runner = CaptureRunner(options: options)
                try await runner.start()
                await Task.detached { runner.wait() }.value
            } catch {
                writeDiagnostic(error.localizedDescription)
                Foundation.exit(1)
            }
        }
    }

#endif
