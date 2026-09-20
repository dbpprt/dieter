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
    var codec = "H264"
    var embeddedCursor = false
    var allowInput = false
    var synthetic = false
    var frameCredits = false
    var referenceRecovery = false
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
            case "--fps": value.fps = try integer(raw, name: name, range: 1...120)
            case "--bitrate-kbps": value.bitrateKbps = try integer(raw, name: name, range: 100...100_000)
            case "--max-width": value.maxWidth = try integer(raw, name: name, range: 320...16_384)
            case "--max-height": value.maxHeight = try integer(raw, name: name, range: 180...16_384)
            case "--event-fd": value.eventFD = Int32(try integer(raw, name: name, range: 3...3))
            case "--codec":
                guard ["H264", "H265"].contains(raw) else { throw CaptureError.invalidArgument("codec") }
                value.codec = raw
            case "--profile": value.profile = raw == "baseline" ? "baseline" : "high"
            case "--embedded-cursor": value.embeddedCursor = raw == "true"
            case "--allow-input": value.allowInput = raw == "true"
            case "--synthetic": value.synthetic = raw == "true"
            case "--frame-credits": value.frameCredits = raw == "true"
            case "--reference-recovery": value.referenceRecovery = raw == "true"
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
    case stopped
    case noDisplay
    case encoder(OSStatus)
    case hevcUnavailable(String)
    case invalidFrame

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let name): "Invalid or missing value for \(name)"
        case .stopped: "native capture rendition stopped"
        case .noDisplay: "The selected display is not available"
        case .hevcUnavailable(let reason): "HEVC encoder unavailable: \(reason)"
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
    let recoveryReference: UInt64
    let overlapped: Bool
    init(
        runner: CaptureRunner, capturedAtNanoseconds: Int64, encodeStartedAt: UInt64, generation: UInt64,
        recoveryReference: UInt64, overlapped: Bool
    ) {
        self.runner = runner
        self.generation = generation
        self.recoveryReference = recoveryReference
        self.overlapped = overlapped
        self.capturedAtNanoseconds = capturedAtNanoseconds
        self.encodeStartedAt = encodeStartedAt
    }
}

struct CapturedFrame {
    let sampleBuffer: CMSampleBuffer
    let capturedAtNanoseconds: Int64
    var changedFraction: Double? = nil
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
    private var credits = CaptureFrameCredits()
    private var lastEncodeDuration: UInt64 = 0
    private var outputBusy = false
    private var pendingFrame: CapturedFrame?
    private var forceKeyFrame = true
    private var ltrEnabled = false
    private var ltrTokens: [UInt64: NSNumber] = [:]
    private var ltrAnchor: (frame: UInt64, token: NSNumber)?
    private var forceLTR = false
    private var ltrRecoveryPending = false
    private var lastRecoveryFrame: UInt64 = 0
    private var recoveryTimeout: DispatchWorkItem?
    private let traceRecovery = ProcessInfo.processInfo.environment["DIETER_TEST_CAPTURE_RECOVERY_DIAGNOSTICS"] == "1"
    private var stopped = false
    private var inputInjector: InputInjector?
    private let inputQueue = DispatchQueue(label: "com.dbpprt.dieter.capture.input", qos: .userInteractive)
    private var configuration: StreamConfiguration
    private var events: EventWriter
    private var generation: UInt64 = 1
    private var frameID: UInt64 = 0
    private var lastOutputGeneration: UInt64 = 0
    private var dropped: UInt64 = 0
    private var outputWidth = 0
    private var outputHeight = 0
    private var selectedDisplaySnapshot: NativeDisplay?
    private var selectedDisplayID: CGDirectDisplayID = 0
    private var paused = false
    private var lastFrame: CapturedFrame?
    private var recoverySchedule = CaptureRecoverySchedule()
    private var encoderConfiguration = ""
    private let burstEnvelope = EncoderBurstEnvelope.configured
    private var contentSum: Double = 0
    private var contentCount: UInt32 = 0
    private var contentSequence: UInt64 = 0
    private var contentFraction: Double?
    private var contentSamples: UInt32 = 0
    private var contentMeasuredAt: UInt64 = 0
    private var contentPublishPending = false
    private let daemonLiveness = NativeDaemonLiveness()
    private var timers: [DispatchSourceTimer] = []
    private let configurationGate = ConfigurationGate()
    private let commands = NativeCommandQueue(capacity: 128)
    private let inputs = NativeCommandQueue(capacity: 128)
    private let configurations = NativeCommandQueue(capacity: 8)
    private var signals: [DispatchSourceSignal] = []
    private var actualEmbeddedCursor = false
    private var forceEmbeddedCursor = false  // stateQueue
    private var lastSystemCursor = NSCursor.arrow
    private var lastCursorGeneration: UInt64 = 0
    private var lastCursorShape = ""
    private var lastCursorPoint = CGPoint(x: -1, y: -1)
    private var lastCursorSentAt: UInt64 = 0
    private var syntheticTimer: DispatchSourceTimer?
    private var syntheticCounter: UInt64 = 0
    private var syntheticInputLuma: Int32 = 128
    private let syntheticInputPattern = ProcessInfo.processInfo.environment["DIETER_TEST_CAPTURE_INPUT_PATTERN"] == "1"
    private let syntheticStarted = DispatchTime.now().uptimeNanoseconds
    private let syntheticIdleCycle = ProcessInfo.processInfo.environment["DIETER_TEST_CAPTURE_IDLE_CYCLE"] == "1"
    private let syntheticQualityCycle = ProcessInfo.processInfo.environment["DIETER_TEST_CAPTURE_QUALITY_CYCLE"] == "1"

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
                if let diagnostic = self.daemonLiveness.timeoutDiagnostic() {
                    writeDiagnostic(diagnostic)
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
        if options.codec == "H265"
            && (config.maxWidth > 1920 || config.maxHeight > 1080 || config.fps > 60 || config.bitrateKbps > 40000)
        {
            throw CaptureError.invalidArgument("HEVC supports at most 1080p60/40000 kbps")
        }
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
                throw CaptureError.stopped
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
        if isStopped { try? await stream.stopCapture(); throw CaptureError.stopped }
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
            guard !isStopped else { throw CaptureError.stopped }
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
        if options.codec == "H265"
            && (config.maxWidth > 1920 || config.maxHeight > 1080 || config.fps > 60 || config.bitrateKbps > 40000)
        {
            throw CaptureError.invalidArgument("HEVC supports at most 1080p60/40000 kbps")
        }
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
                contentSum = 0; contentCount = 0; contentFraction = nil; contentSamples = 0
                syntheticTimer?.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / config.fps))
            }
            try await startStream()
            stateQueue.sync { paused = false }
        } else {
            let values = stateQueue.sync { (stream, outputWidth, outputHeight) }
            if let stream = values.0, old.fps != config.fps || old.embeddedCursor != config.embeddedCursor {
                try await stream.updateConfiguration(streamConfiguration(config, values.1, values.2))
            }
            if let sharedDisplay, old.fps != config.fps || old.embeddedCursor != config.embeddedCursor {
                try await SharedDisplayPool.shared.update(
                    display: sharedDisplay, id: options.streamID,
                    width: values.1, height: values.2, fps: config.fps, cursor: config.embeddedCursor)
            }
            try stateQueue.sync {
                if let encoder {
                    if old.bitrateKbps != config.bitrateKbps {
                        try configureRate(encoder, kbps: config.bitrateKbps)
                    }
                    if old.fps != config.fps {
                        try set(encoder, kVTCompressionPropertyKey_ExpectedFrameRate, config.fps as CFNumber)
                    }
                }
                if old.fps != config.fps {
                    syntheticTimer?.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / config.fps))
                }
                configuration = config
                // VideoToolbox applies rate changes to subsequent frames. A
                // bitrate recovery must not inject another large IDR burst.
            }
            emitState()
        }
    }

    private func emitState() {
        let state = stateQueue.sync { stateSnapshot() }
        if !events.send(NativeEvent(state: state)) { stop() }
    }

    // stateQueue only. Content snapshots use the same generation/configuration
    // contract as ordinary state and never block capture on a diagnostic write.
    private func stateSnapshot() -> NativeState {
        NativeState(
                width: outputWidth, height: outputHeight, fps: configuration.fps,
                bitrateKbps: configuration.bitrateKbps,
                displayId: options.synthetic ? "synthetic" : String(selectedDisplayID), displayGeneration: generation,
                encoder: options.codec == "H265"
                    ? "VideoToolbox HEVC Main"
                    : options.profile == "high"
                        ? "VideoToolbox H.264 High / low latency" : "VideoToolbox H.264 Baseline / low latency",
                embeddedCursor: options.multiplex && !options.synthetic
                    ? actualEmbeddedCursor : configuration.embeddedCursor,
                encoderConfiguration: encoderConfiguration)
    }

    private func observeContent(_ frame: CapturedFrame) {
        guard let fraction = frame.changedFraction, fraction.isFinite, (0...1).contains(fraction) else { return }
        contentSum += fraction; contentCount += 1
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - contentMeasuredAt >= 500_000_000 else { return }
        contentFraction = contentSum / Double(contentCount); contentSamples = contentCount
        contentCount = 0; contentSum = 0; contentMeasuredAt = now; contentSequence &+= 1
        guard !contentPublishPending else { return }
        contentPublishPending = true
        let content = NativeContent(generation: generation, sequence: contentSequence,
            samples: contentSamples, changedFraction: contentFraction ?? 1)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            if !self.isStopped && !self.events.send(NativeEvent(content: content)) { self.stop() }
            self.stateQueue.async { self.contentPublishPending = false }
        }
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

    func stop(reason: String = "native capture rendition stopped") {
        stopLock.lock()
        if stopped {
            stopLock.unlock()
            return
        }
        stopped = true
        let stoppedTimers = timers
        timers.removeAll()
        stopLock.unlock()
        commands.close(); inputs.close(); configurations.close()
        for timer in stoppedTimers { timer.cancel() }
        if options.multiplex { _ = events.send(NativeEvent(error: reason)) }
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
                    self.recoveryTimeout?.cancel(); self.recoveryTimeout = nil
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
            capturedAtNanoseconds: Int64(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds * 1_000_000_000),
            changedFraction: captureChangedFraction(sampleBuffer))
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
        observeContent(frame)
        // A new/recovering encoder still needs an initial decodable frame even
        // on an unchanged display. Unknown damage always keeps the old path.
        if frame.changedFraction == 0 && lastOutputGeneration == generation && lastFrame != nil && !forceKeyFrame && !forceLTR &&
            !actualEmbeddedCursor && !configuration.embeddedCursor {
            lastFrame = frame
            return
        }
        lastFrame = frame
        if pendingFrame != nil { dropped += 1 }
        pendingFrame = frame
        admitPendingFrame()
    }

    private func admitPendingFrame() {
        guard !paused, !encoding, !outputBusy, let next = pendingFrame else { return }
        let captureNow = Int64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * 1_000_000_000)
        if options.frameCredits && !credits.canEncode(generation: generation, now: DispatchTime.now().uptimeNanoseconds,
            frameAge: UInt64(max(0, captureNow - next.capturedAtNanoseconds)), encodeEstimate: lastEncodeDuration) { return }
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
        do { try initializeEncoder(width: width, height: height) } catch {
            // LTR is optional. Older HEVC hardware keeps the existing encoder
            // mode if it cannot create Apple's low-latency encoder variant.
            if options.codec == "H265" && options.referenceRecovery {
                if let encoder { VTCompressionSessionInvalidate(encoder) }; encoder = nil
                do { try initializeEncoder(width: width, height: height, lowLatencyHEVC: false); return } catch {
                    throw CaptureError.hevcUnavailable(error.localizedDescription)
                }
            }
            if options.codec == "H265" { throw CaptureError.hevcUnavailable(error.localizedDescription) }; throw error
        }
    }

    private func initializeEncoder(width: Int, height: Int, lowLatencyHEVC: Bool = true) throws {
        if options.codec == "H265"
            && (width > 1920 || height > 1080 || configuration.fps > 60 || configuration.bitrateKbps > 40000)
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
        encoderConfiguration = ""
        ltrTokens.removeAll(); ltrAnchor = nil; forceLTR = false; ltrRecoveryPending = false; lastRecoveryFrame = 0
        recoveryTimeout?.cancel(); recoveryTimeout = nil; recoverySchedule.acknowledgeRecovery()
        ltrEnabled =
            options.referenceRecovery
            && VTSessionSetProperty(session, key: kVTCompressionPropertyKey_EnableLTR, value: kCFBooleanTrue) == noErr
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
                    ? kVTProfileLevel_H264_High_AutoLevel : kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel))
        // HEVC hardware does not expose MaxFrameDelayCount. Frame reordering is
        // disabled, and the existing single frame credit bounds encoder work.
        try set(session, kVTCompressionPropertyKey_ExpectedFrameRate, configuration.fps as CFNumber)
        try configureRate(session, kbps: configuration.bitrateKbps)
        let speedStatus = VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        encoderConfiguration += "; speedPriority=\(speedStatus == noErr ? "accepted" : "rejected(\(speedStatus))")"
        writeDiagnostic("encoder configuration codec=\(options.codec) \(encoderConfiguration)")
        try set(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, (configuration.fps * 10) as CFNumber)
        try set(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 10 as CFNumber)
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else { throw CaptureError.encoder(prepareStatus) }
    }

    private func set(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else {
            throw NSError(
                domain: "DieterCapture", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "VideoToolbox property \(key) failed with status \(status)"])
        }
    }

    private func configureRate(_ session: VTCompressionSession, kbps: Int) throws {
        try set(session, kVTCompressionPropertyKey_AverageBitRate, (kbps * 1000) as CFNumber)
        let burst = burstEnvelope.apply(kbps: kbps) {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: $0)
        }
        let suffix = encoderConfiguration.split(separator: ";").last.map(String.init)
        encoderConfiguration = "hardware=required; realtime=accepted; reorder=disabled; \(burst)"
        if let suffix, suffix.contains("speedPriority=") { encoderConfiguration += ";\(suffix)" }
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
            encodeStartedAt: DispatchTime.now().uptimeNanoseconds, generation: generation,
            recoveryReference: forceLTR && !forceKeyFrame ? (ltrAnchor?.frame ?? 0) : 0,
            overlapped: !credits.frames.isEmpty
        )
        var properties: [String: Any] = [:]
        if ltrEnabled, let anchor = ltrAnchor {
            properties[kVTEncodeFrameOptionKey_AcknowledgedLTRTokens as String] = [anchor.token]
        }
        if forceKeyFrame {
            properties[kVTEncodeFrameOptionKey_ForceKeyFrame as String] = true; forceKeyFrame = false
        } else if forceLTR {
            properties[kVTEncodeFrameOptionKey_ForceLTRRefresh as String] = true
        }
        forceLTR = false
        let status = VTCompressionSessionEncodeFrame(
            encoder,
            imageBuffer: outputBuffer,
            presentationTimeStamp: CMTime(value: frame.capturedAtNanoseconds, timescale: 1_000_000_000),
            duration: CMTime(value: 1, timescale: CMTimeScale(configuration.fps)),
            frameProperties: properties as CFDictionary,
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
            if traceRecovery && (keyFrame || context.recoveryReference != 0) {
                writeDiagnostic("recovery output generation=\(generation) frame=\(frameID + 1) key=\(keyFrame) reference=\(context.recoveryReference)")
            }
            if context.recoveryReference != 0 && !keyFrame {
                lastRecoveryFrame = frameID + 1
                if recoverySchedule.producedReference(now: DispatchTime.now().uptimeNanoseconds) {
                    armRecoveryTimeout()
                }
            }
            if keyFrame {
                lastRecoveryFrame = 0; ltrAnchor = nil; ltrTokens.removeAll(); ltrRecoveryPending = false
                recoveryTimeout?.cancel(); recoveryTimeout = nil; recoverySchedule.acknowledgeRecovery()
            }
            let attachments =
                CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]]
            let ltrToken =
                ltrEnabled
                ? attachments?.first?[kVTSampleAttachmentKey_RequireLTRAcknowledgementToken as String] as? NSNumber
                : nil
            if let ltrToken {
                ltrTokens[frameID + 1] = ltrToken
                for id in ltrTokens.keys.sorted().dropLast(256) { ltrTokens.removeValue(forKey: id) }
            }
            let accessUnit = try annexB(sampleBuffer, includeParameterSets: keyFrame || context.recoveryReference != 0)
            let encodeDuration = DispatchTime.now().uptimeNanoseconds - context.encodeStartedAt
            lastEncodeDuration = encodeDuration
            writeFrame(
                accessUnit,
                keyFrame: keyFrame,
                captureNanoseconds: context.capturedAtNanoseconds,
                encodeNanoseconds: encodeDuration, ltrToken: ltrToken,
                recoveryReference: keyFrame ? 0 : context.recoveryReference, overlapped: context.overlapped
            )
        } catch {
            stop(reason: "encode output failed: \(error.localizedDescription)")
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
        let parameterSet =
            options.codec == "H265"
            ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex : CMVideoFormatDescriptionGetH264ParameterSetAtIndex
        let queryStatus = parameterSet(
            format, 0, nil, nil, &count, &headerLength
        )
        guard queryStatus == noErr else { throw CaptureError.encoder(queryStatus) }
        guard (1...4).contains(headerLength) else { throw CaptureError.invalidFrame }
        if includeParameterSets {
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let parameterStatus = parameterSet(
                    format, index, &pointer, &size, nil, nil
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
        guard totalLength <= CaptureFrameCredits.maxAccessUnitBytes else { throw CaptureError.invalidFrame }
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
            guard output.count <= CaptureFrameCredits.maxAccessUnitBytes else { throw CaptureError.invalidFrame }
            offset += length
        }
        guard offset == totalLength else { throw CaptureError.invalidFrame }
        return output
    }

    private func writeFrame(
        _ payload: Data,
        keyFrame: Bool,
        captureNanoseconds: Int64,
        encodeNanoseconds: UInt64, ltrToken: NSNumber?, recoveryReference: UInt64, overlapped: Bool
    ) {
        guard payload.count <= CaptureFrameCredits.maxAccessUnitBytes else { stop(reason: "encoded frame exceeds bounds"); return }
        frameID += 1
        var header = Data()
        if options.multiplex { header.appendBigEndian(options.streamID) }
        header.appendBigEndian(UInt32(payload.count))
        header.appendBigEndian(
            UInt32((keyFrame ? 1 : 0) | (ltrToken != nil ? 2 : 0) | (recoveryReference != 0 ? 4 : 0) | (overlapped ? 8 : 0)))
        header.appendBigEndian(frameID)
        header.appendBigEndian(generation)
        header.appendBigEndian(UInt64(bitPattern: captureNanoseconds))
        header.appendBigEndian(encodeNanoseconds)
        let now = Int64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * 1_000_000_000)
        header.appendBigEndian(UInt64(max(0, now - captureNanoseconds)))
        header.appendBigEndian(UInt32(outputWidth))
        header.appendBigEndian(UInt32(outputHeight))
        header.appendBigEndian(dropped)
        if let ltrToken { header.appendBigEndian(ltrToken.uint64Value) }
        if recoveryReference != 0 { header.appendBigEndian(recoveryReference) }
        if options.frameCredits && !credits.produced(id: frameID, generation: generation, bytes: payload.count) {
            stop(reason: "native encoder exceeded its frame credit"); return
        }
        lastOutputGeneration = generation
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
                    guard let command = try? decoder.decode(NativeCommand.self, from: data), command.version == CaptureContract.version else {
                        self.stop(); return
                    }
                    self.daemonLiveness.receive(command.kind)
                    if command.kind == "heartbeat" {
                        if !self.events.send(NativeEvent(ack: command.id)) { self.stop(); return }
                    } else {
                        self.enqueue(command) { error in
                            if !self.events.send(NativeEvent(ack: command.id, error: error)) { self.stop() }
                        }
                    }
                }
                if pending.count > 16384 { break }
            }
            self.inputQueue.sync { self.inputInjector?.releaseAll() }
            self.stop()
        }
    }

    func enqueue(_ command: NativeCommand, reply: @escaping (String?) -> Void) {
        let queue =
            ["configure", "display_changed"].contains(command.kind)
            ? configurations : (command.kind == "input" ? inputs : commands)
        if !queue.submit({
            do { try await self.handle(command); reply(nil) } catch { reply(error.localizedDescription) }
        }) {
            reply(isStopped ? CaptureError.stopped.localizedDescription : "Native command queue is full")
        }
    }

    func handle(_ command: NativeCommand) async throws {
        guard !isStopped else { throw CaptureError.stopped }
        switch command.kind {
        case "heartbeat":
            daemonLiveness.receive(command.kind)
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
            // Opt-in fixture responds to input with encoded pixels. No real
            // desktop/session can enter this synthetic measurement path.
            if options.synthetic && syntheticInputPattern && input.kind == "text",
                input.text.hasPrefix("dieter-latency:"),
                let luma = Int32(input.text.dropFirst("dieter-latency:".count)), [16, 235].contains(luma)
            {
                stateQueue.async { [self] in
                    syntheticInputLuma = luma; syntheticFrame(force: true)
                }
            }
        case "configure":
            // Synthetic fault injection never delays a real desktop session.
            if options.synthetic, let raw = ProcessInfo.processInfo.environment["DIETER_TEST_CAPTURE_CONFIG_DELAY_MS"],
                let delay = UInt64(raw), delay <= 5000
            {
                try await Task.sleep(nanoseconds: delay * 1_000_000)
            }
            guard let config = command.configuration else {
                throw CaptureError.invalidArgument("configuration")
            }
            try await self.reconfigure(config)
        case "display_changed":
            try await self.reconfigure(nil, force: true)
        case "frame_sending":
            stateQueue.sync {
                guard options.frameCredits, let id = command.frameId, let frameGeneration = command.generation else { return }
                credits.sending(id: id, generation: frameGeneration, now: DispatchTime.now().uptimeNanoseconds,
                    budgetMS: command.overlapBudgetMs ?? 0)
                admitPendingFrame()
            }
        case "frame_consumed":
            if options.synthetic, let raw = ProcessInfo.processInfo.environment["DIETER_TEST_CAPTURE_CREDIT_DELAY_MS"],
                let delay = UInt64(raw), delay <= 5000
            {
                try await Task.sleep(nanoseconds: delay * 1_000_000)
            }
            self.stateQueue.sync {
                if let frameID = command.frameId, let generation = command.generation,
                    self.credits.consumed(id: frameID, generation: generation) {
                    self.admitPendingFrame()
                }
            }
        case "ack_recovery":
            try self.stateQueue.sync {
                guard command.generation == generation, command.frameId == lastRecoveryFrame, lastRecoveryFrame != 0
                else {
                    if traceRecovery { writeDiagnostic("recovery ACK retired frame=\(command.frameId ?? 0) active=\(lastRecoveryFrame)") }
                    throw CaptureError.invalidArgument("recovery acknowledgment")
                }
                if traceRecovery { writeDiagnostic("recovery ACK accepted frame=\(lastRecoveryFrame)") }
                ltrRecoveryPending = false; lastRecoveryFrame = 0
                recoveryTimeout?.cancel(); recoveryTimeout = nil; recoverySchedule.acknowledgeRecovery()
            }
        case "ack_reference":
            try self.stateQueue.sync {
                guard ltrEnabled, command.generation == generation, let id = command.frameId,
                    let token = ltrTokens[id], token.uint64Value == command.ltrToken
                else { throw CaptureError.invalidArgument("reference acknowledgment") }
                // One anchor per keyframe interval. The dependency descriptor can
                // name the exact reference even if the hardware retains old LTRs.
                if ltrAnchor == nil { ltrAnchor = (id, token) }
            }
        case "recover": self.stateQueue.sync { self.refresh(recover: true, windowMS: command.recoveryWindowMs ?? 200) }
        case "refresh": self.stateQueue.sync { self.refresh() }
        case "stop":
            self.inputQueue.sync { self.inputInjector?.releaseAll() }
            self.stop()
        default: throw CaptureError.invalidArgument("command kind")
        }
    }

    private func refresh(recover: Bool = false, windowMS: Int = 200) {
        let now = DispatchTime.now().uptimeNanoseconds
        let referenceAvailable = recover && ltrEnabled && ltrAnchor.map { frameID - $0.frame < 8000 } == true
        guard let useReference = recoverySchedule.request(now: now, windowMS: windowMS,
            referenceAvailable: referenceAvailable, pending: ltrRecoveryPending) else { return }
        if traceRecovery { writeDiagnostic("recovery request generation=\(generation) useReference=\(useReference) pending=\(ltrRecoveryPending) windowMs=\(windowMS)") }
        recoveryTimeout?.cancel(); recoveryTimeout = nil
        if useReference {
            forceLTR = true; ltrRecoveryPending = true
            armRecoveryTimeout()
        } else {
            forceKeyFrame = true; forceLTR = false
        }
        if let lastFrame {
            // A refresh is a new presentation of retained pixels, not an old RTP time.
            let time = Int64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * 1_000_000_000)
            offer(CapturedFrame(sampleBuffer: lastFrame.sampleBuffer, capturedAtNanoseconds: time))
        }
    }

    private func armRecoveryTimeout() {
        recoveryTimeout?.cancel(); recoveryTimeout = nil
        guard let deadline = recoverySchedule.referenceDeadline else { return }
        let attempt = recoverySchedule.lastAttempt, epoch = generation
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped, self.generation == epoch,
                self.recoverySchedule.lastAttempt == attempt, self.ltrRecoveryPending,
                self.recoverySchedule.expireReference(now: DispatchTime.now().uptimeNanoseconds)
            else { return }
            self.recoveryTimeout = nil
            if self.traceRecovery { writeDiagnostic("recovery ACK deadline expired frame=\(self.lastRecoveryFrame)") }
            self.refresh(windowMS: self.recoverySchedule.referenceWindowMS)
        }
        recoveryTimeout = timeout
        stateQueue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline), execute: timeout)
    }

    private func syntheticFrame(force: Bool = false) {
        guard !paused else { return }
        if syntheticQualityCycle && !force {
            let elapsed = (DispatchTime.now().uptimeNanoseconds - syntheticStarted) / 1_000_000_000 % 180
            if (8..<53).contains(elapsed) || ((53..<143).contains(elapsed) && elapsed % 2 == 0) { return }
        } else if syntheticIdleCycle && !force {
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
        if syntheticInputPattern, let base = CVPixelBufferGetBaseAddressOfPlane(pixel, 0) {
            for row in 0..<min(64, outputHeight) {
                memset(
                    base.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)), syntheticInputLuma,
                    min(64, outputWidth))
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
        let frame = CapturedFrame(sampleBuffer: sample, capturedAtNanoseconds: Int64(pts.seconds * 1_000_000_000), changedFraction: 1)
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
        // A transiently unavailable system shape must not burn a second cursor
        // into the video. Retain the last valid shape (initially the arrow), so
        // clients keep moving their local hardware cursor without a round trip.
        let candidate = NSCursor.currentSystem ?? lastSystemCursor
        let cursor: NSCursor
        let png: Data
        if let encoded = cursorPNG(candidate) {
            cursor = candidate; png = encoded; lastSystemCursor = candidate
        } else if let encoded = cursorPNG(lastSystemCursor) {
            cursor = lastSystemCursor; png = encoded
        } else {
            return
        }
        let shape = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let state = inputQueue.sync {
            (
                bounds: inputInjector?.bounds ?? .zero,
                ordinal: inputInjector?.lastOrdinal ?? 0,
                point: inputInjector?.dryRun == true
                    ? inputInjector?.position ?? .zero : CGEvent(source: nil)?.location ?? .zero
            )
        }
        guard state.bounds.width > 0, state.bounds.height > 0 else { return }
        let point = state.point
        let now = DispatchTime.now().uptimeNanoseconds
        guard
            config.1 != lastCursorGeneration || shape != lastCursorShape || point != lastCursorPoint
                || now - lastCursorSentAt > 1_000_000_000
        else {
            return
        }
        let x = Int32(max(0, min(1, (point.x - state.bounds.minX) / state.bounds.width)) * 1_000_000)
        let y = Int32(max(0, min(1, (point.y - state.bounds.minY) / state.bounds.height)) * 1_000_000)
        let value = NativeCursor(
            shapeId: shape, png: shape == lastCursorShape ? nil : png, hotspotX: cursor.hotSpot.x,
            hotspotY: cursor.hotSpot.y, width: cursor.image.size.width, height: cursor.image.size.height,
            normalizedX: x, normalizedY: y, visible: state.bounds.contains(point), displayGeneration: config.1,
            lastInputOrdinal: state.ordinal)
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

func writeDiagnostic(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func hardwareEncoderAvailable(_ codec: CMVideoCodecType = kCMVideoCodecType_H264) -> Bool {
    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(
        allocator: kCFAllocatorDefault, width: 1920, height: 1080,
        codecType: codec,
        encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
            as CFDictionary,
        imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
        compressionSessionOut: &session)
    guard status == noErr, let session else { return false }
    defer { VTCompressionSessionInvalidate(session) }
    var hardware: CFTypeRef?
    let query = withUnsafeMutablePointer(to: &hardware) {
        VTSessionCopyProperty(
            session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: $0)
    }
    guard query == noErr, hardware as? Bool == true else { return false }
    if codec == kCMVideoCodecType_HEVC {
        guard
            VTSessionSetProperty(
                session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
                == noErr,
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue) == noErr,
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
                == noErr
        else { return false }
    }
    return true
}

#if !DIETER_CAPTURE_TEST
    @main
    private struct DieterCapture {
        static func main() async {
            do {
                if CommandLine.arguments.contains("--display-service") {
                    let dryRun = CommandLine.arguments.contains("--dry-run")
                    await Task.detached { DisplayModeService.run(dryRun: dryRun) }.value
                    return
                }
                if CommandLine.arguments.contains("--clipboard-service") {
                    await Task.detached { ClipboardService.run() }.value
                    return
                }
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
                    let hevc = hardwareEncoderAvailable(kCMVideoCodecType_HEVC)
                    let value: [String: Any] = [
                        "platform": "darwin", "helper_version": "native-v\(CaptureContract.version)",
                        "graphical_session_active": synthetic || !displays.isEmpty,
                        "capture_permission": granted ? "granted" : "denied",
                        "control_permission": (synthetic || CGPreflightPostEventAccess()) ? "granted" : "denied",
                        "displays": displayJSON, "codecs": hevc ? ["H264", "H265"] : ["H264"],
                        "codec_modes": hevc
                            ? [
                                [
                                    "codec": "H265", "profile": "main", "max_width": 1920, "max_height": 1080,
                                    "max_fps": 60,
                                ]
                            ] : [],
                        "encoder_available": hardwareEncoderAvailable(), "control_supported": true,
                        "adaptive_supported": true, "cursor_supported": true, "input_protocol_version": CaptureContract.version,
                        "display_mode_switching_supported": true,
                        "max_fps": 120, "encoder": "VideoToolbox H.264",
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
