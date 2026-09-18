import CoreVideo
@preconcurrency import MetalKit
@preconcurrency import WebRTC

enum RemoteDesktopPresentationMode: String, Sendable {
    case immediate
    case displayLink = "display-link"
    case bounded
    case lowLatency = "low-latency"
    // Keep display timing opt-in until physical input/presentation A/B testing.
    static var configured: Self {
        Self(rawValue: ProcessInfo.processInfo.environment["DIETER_SCREEN_PRESENTATION"] ?? "") ?? .immediate
    }
}

// All mutable GPU state is confined to executor. Only the mailbox and metrics
// cross threads, under locks. One GPU submission and one replaceable frame bound
// latency and IOSurface retention even if rendering or the UI stalls.
final class RemoteDesktopMetalRenderer: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    let mode: RemoteDesktopPresentationMode
    private(set) var initializationFailure: String?
    private let layer: CAMetalLayer
    private let executor = RemoteDesktopRenderExecutor()
    private let mailbox = RemoteDesktopRenderMailbox()
    private let statistics = RemoteDesktopRenderStatistics()
    let trace = RemoteDesktopRenderTrace()
    private var presentations: RemoteDesktopPresentationLedger
    private var presentationWatchdogScheduled = false
    private let wakeUI: @Sendable () -> Void
    private var commandQueue: (any MTLCommandQueue)?
    private var nv12Pipeline: (any MTLRenderPipelineState)?
    private var rgbPipeline: (any MTLRenderPipelineState)?
    private var textureCache: CVMetalTextureCache?
    private var displayLink: CAMetalDisplayLink?
    private var size = CGSize.zero
    private var attached = false
    private var gpuBusy = false
    private var lastWorkAt: Double = 0
    private var stopped = false
    private var lastFrame: (RTCVideoFrame, UInt64)?

    init(layer: CAMetalLayer, mode: RemoteDesktopPresentationMode, wakeUI: @escaping @Sendable () -> Void) {
        self.layer = layer; self.mode = mode; self.wakeUI = wakeUI
        presentations = RemoteDesktopPresentationLedger(limit: mode == .bounded ? 1 : 2)
        super.init()
        guard let device = MTLCreateSystemDefaultDevice() else {
            initializationFailure = "Metal is unavailable on this Mac."; return
        }
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.maximumDrawableCount = 2
        layer.displaySyncEnabled = mode != .lowLatency
        layer.presentsWithTransaction = false
        layer.framebufferOnly = true
        layer.allowsNextDrawableTimeout = true
        do {
            commandQueue = device.makeCommandQueue()
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            func pipeline(_ fragment: String) throws -> any MTLRenderPipelineState {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "screenVertex")
                descriptor.fragmentFunction = library.makeFunction(name: fragment)
                descriptor.colorAttachments[0].pixelFormat = layer.pixelFormat
                return try device.makeRenderPipelineState(descriptor: descriptor)
            }
            nv12Pipeline = try pipeline("screenNV12")
            rgbPipeline = try pipeline("screenRGB")
            guard commandQueue != nil,
                CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache) == kCVReturnSuccess
            else { throw NSError(domain: "DieterMetal", code: 1) }
        } catch {
            initializationFailure = "The native screen renderer could not initialize: \(error.localizedDescription)"
        }
    }

    var snapshot: RemoteDesktopRenderSnapshot { statistics.snapshot }
    func consumeUpdate() -> RemoteDesktopRenderSnapshot { statistics.consume() }
    func isCurrent(_ token: UInt64) -> Bool { mailbox.isCurrent(token) }
    func decodeHandler() -> @Sendable (RTCVideoFrame) -> Void {
        let token = mailbox.currentToken
        return { [weak self] frame in self?.offer(frame, token: token) }
    }
    func offer(_ frame: RTCVideoFrame, token: UInt64? = nil) {
        guard mailbox.offer(frame, expectedToken: token, wakeForCadence: mode == .bounded) else { return }
        executor.perform { [weak self] in self?.wake() }
    }
    func redraw() {
        executor.perform { [weak self] in
            guard let self, !self.stopped, let (frame, token) = self.lastFrame else { return }
            self.offer(frame, token: token)
        }
    }
    func reset() {
        let token = mailbox.reset()
        statistics.reset(token: token)
        executor.perform { [weak self] in
            guard let self else { return }
            self.presentations.invalidatePresentations()
            if self.lastFrame?.1 != self.mailbox.currentToken { self.lastFrame = nil }
            if !self.gpuBusy { self.completeDraw() }
        }
    }
    func shutdown() {
        mailbox.close()
        executor.perform { [self] in
            stopped = true; lastFrame = nil
            presentations.invalidatePresentations()
            displayLink?.invalidate(); displayLink = nil
            if !gpuBusy { executor.stop() }
        }
    }
    func resize(_ size: CGSize, scale: CGFloat, attached: Bool) {
        executor.perform { [weak self] in
            guard let self, !self.stopped else { return }
            let pixels = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
            let changed = self.size != size || self.layer.drawableSize != pixels || self.attached != attached
            self.size = size; self.attached = attached
            self.layer.drawableSize = pixels
            self.layer.contentsScale = scale
            if changed, attached, !self.mailbox.hasPending, let (frame, token) = self.lastFrame {
                self.offer(frame, token: token)
            }
            if !attached { self.displayLink?.isPaused = true }
        }
    }
    private func wake() {
        guard !stopped, !gpuBusy else { return }
        if mode == .bounded { presentations.limit = mailbox.presentationBudget }
        guard presentations.canSubmit else { schedulePresentationWatchdog(); return }
        guard attached, size.width > 0, size.height > 0, mailbox.hasPending else {
            _ = mailbox.take(); completeDraw(); return
        }
        lastWorkAt = CACurrentMediaTime()
        if mode == .displayLink {
            if displayLink == nil {
                let link = CAMetalDisplayLink(metalLayer: layer)
                link.delegate = self
                link.preferredFrameLatency = 1
                link.add(to: .current, forMode: .default)
                displayLink = link
            }
            displayLink?.isPaused = false
        } else {
            // Select the latest frame AFTER nextDrawable's compositor wait.
            let requestedAt = CACurrentMediaTime()
            render(drawable: layer.nextDrawable(), targetPresentation: nil, drawableRequestedAt: requestedAt)
        }
    }
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        autoreleasepool {
            guard !stopped, attached, !gpuBusy, presentations.canSubmit, mailbox.hasPending else {
                pauseDisplayLinkIfIdle()
                return
            }
            render(drawable: update.drawable, targetPresentation: update.targetPresentationTimestamp, drawableRequestedAt: CACurrentMediaTime())
        }
    }
    private func completeDraw() {
        gpuBusy = false
        if mailbox.complete() {
            // Yield to the run loop, allowing resize/reset and display callbacks.
            executor.perform { [weak self] in self?.wake() }
        } else {
            pauseDisplayLinkIfIdle()
        }
    }
    private func pauseDisplayLinkIfIdle() {
        // Repeatedly pausing between 60 Hz frames re-primes the display link
        // and can halve its cadence. Allow a short idle grace, then stop ticks.
        if !gpuBusy && (!attached || stopped || CACurrentMediaTime() - lastWorkAt >= 0.1) {
            displayLink?.isPaused = true
        }
    }
    private func schedulePresentationWatchdog() {
        guard !stopped, !presentationWatchdogScheduled, presentations.outstanding > 0 else { return }
        presentationWatchdogScheduled = true
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.executor.perform { [weak self] in
                guard let self, !self.stopped else { return }
                self.presentationWatchdogScheduled = false
                let expired = self.presentations.expire(at: CACurrentMediaTime())
                if expired > 0 {
                    let token = self.mailbox.currentToken
                    if self.statistics.update(token: token, { $0.presentationTimeouts &+= UInt64(expired) }) { self.wakeUI() }
                    self.wake()
                }
                self.schedulePresentationWatchdog()
            }
        }
    }
    private func fail(_ message: String, token: UInt64) {
        if statistics.update(token: token, { $0.failure = message }) { wakeUI() }
    }
    private func render(drawable: (any CAMetalDrawable)?, targetPresentation: Double?, drawableRequestedAt: Double) {
        let drawableReadyAt = CACurrentMediaTime()
        guard let drawable else { _ = mailbox.take(); completeDraw(); return }
        guard let (frame, token, arrivedAt) = mailbox.take() else { completeDraw(); return }
        guard initializationFailure == nil, let queue = commandQueue, let cache = textureCache,
            let native = frame.buffer as? RTCCVPixelBuffer
        else {
            completeDraw();
            fail(initializationFailure ?? "The screen decoder did not supply a native pixel buffer.", token: token);
            return
        }
        let pixel = native.pixelBuffer
        let format = CVPixelBufferGetPixelFormatType(pixel)
        let isNV12 =
            format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard isNV12 || format == kCVPixelFormatType_32BGRA else {
            completeDraw(); fail("The screen decoder supplied an unsupported pixel format.", token: token); return
        }
        let rotated = frame.rotation == ._90 || frame.rotation == ._270
        let videoSize = CGSize(
            width: CGFloat(rotated ? frame.height : frame.width), height: CGFloat(rotated ? frame.width : frame.height))
        guard let command = queue.makeCommandBuffer(), let pipeline = isNV12 ? nv12Pipeline : rgbPipeline else {
            completeDraw(); return
        }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        var retained: [CVMetalTexture] = []
        func texture(_ plane: Int, _ format: MTLPixelFormat) -> (any MTLTexture)? {
            var reference: CVMetalTexture?
            let planar = CVPixelBufferIsPlanar(pixel)
            let width = planar ? CVPixelBufferGetWidthOfPlane(pixel, plane) : CVPixelBufferGetWidth(pixel)
            let height = planar ? CVPixelBufferGetHeightOfPlane(pixel, plane) : CVPixelBufferGetHeight(pixel)
            guard
                CVMetalTextureCacheCreateTextureFromImage(
                    nil, cache, pixel, nil, format, width, height, plane, &reference) == kCVReturnSuccess,
                let reference
            else { return nil }
            retained.append(reference)
            return CVMetalTextureGetTexture(reference)
        }
        guard let first = texture(0, isNV12 ? .r8Unorm : .bgra8Unorm) else {
            completeDraw(); fail("The screen pixel buffer could not be mapped into Metal.", token: token); return
        }
        let chroma = isNV12 ? texture(1, .rg8Unorm) : nil
        guard !isNV12 || chroma != nil, let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
            completeDraw(); fail("The screen texture could not be rendered.", token: token); return
        }
        let aspect = videoSize.width / videoSize.height, surfaceAspect = size.width / size.height
        var geometry = SIMD4<Float>(
            Float(min(1, aspect / surfaceAspect)), Float(min(1, surfaceAspect / aspect)),
            Float(frame.rotation.rawValue / 90), 0)
        let matrix = CVBufferCopyAttachment(pixel, kCVImageBufferYCbCrMatrixKey, nil) as? String
        var coefficients =
            matrix == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
            ? SIMD4<Float>(1.402, -0.344136, -0.714136, 1.772) : SIMD4<Float>(1.5748, -0.187324, -0.468124, 1.8556)
        let limited = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        var range = SIMD4<Float>(
            limited ? 255.0 / 219 : 1, limited ? 16.0 / 255 : 0, limited ? 255.0 / 224 : 1, 128.0 / 255)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&geometry, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentTexture(first, index: 0)
        if let chroma { encoder.setFragmentTexture(chroma, index: 1) }
        encoder.setFragmentBytes(&coefficients, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentBytes(&range, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        guard mailbox.isCurrent(token), let submissionID = presentations.begin(token: token, at: CACurrentMediaTime()) else {
            completeDraw(); return
        }
        let submission = RemoteDesktopMetalSubmission(frame: frame, textures: retained, token: token)
        trace.append(RemoteDesktopRenderTraceRecord(submission: submissionID, epoch: token,
            rtpTimestamp: UInt32(bitPattern: frame.timeStamp), decodedAt: arrivedAt,
            drawableRequestedAt: drawableRequestedAt, drawableReadyAt: drawableReadyAt, committedAt: CACurrentMediaTime()))
        drawable.addPresentedHandler { [weak self, submission] drawable in
            guard let self else { return }
            let presentedAt = drawable.presentedTime
            self.trace.update(submissionID) {
                $0.presentedAt = presentedAt > 0 ? presentedAt : nil
                $0.presentationCallbackAt = CACurrentMediaTime()
            }
            self.executor.perform { [weak self] in
                guard let self, !self.stopped else { return }
                _ = self.presentations.presented(submissionID)
                self.wake()
            }
            if self.statistics.update(
                token: submission.token,
                { state in
                    guard submissionID > state.lastPresentedSubmission else { return }
                    state.lastPresentedSubmission = submissionID
                    var timing: Double = 0
                    if state.lastTimestamp != submission.frame.timeStamp {
                        state.framesPresented &+= 1
                        state.lastTimestamp = submission.frame.timeStamp
                    }
                    // Presentation can be reported before its hardware timestamp
                    // is available (notably the first drawable in a new window).
                    // Keep visibility events and valid timing samples independent.
                    if state.lastTimedTimestamp != submission.frame.timeStamp,
                        presentedAt >= arrivedAt, presentedAt > 0
                    {
                        state.lastTimedTimestamp = submission.frame.timeStamp
                        state.totalRenderMilliseconds += (presentedAt - arrivedAt) * 1000
                        state.timedPresentations &+= 1
                        timing = presentedAt
                        if let targetPresentation, presentedAt > targetPresentation + 0.002 {
                            state.latePresentations &+= 1
                        }
                    }
                    state.presentation = RemoteDesktopPresentation(frame: submission.frame, presentedAt: timing)
                })
            {
                self.wakeUI()
            }
        }
        command.addCompletedHandler { [weak self, submission] command in
            // IOSurface/CVMetalTexture wrappers remain alive through GPU use.
            _ = submission
            let failure = command.error?.localizedDescription
            self?.trace.update(submissionID) {
                $0.gpuStartedAt = command.gpuStartTime > 0 ? command.gpuStartTime : nil
                $0.gpuCompletedAt = command.gpuEndTime > 0 ? command.gpuEndTime : nil
            }
            self?.executor.perform { [weak self, submission] in
                guard let self, self.presentations.completedGPU(submissionID) else { return }
                self.completeDraw()
                if let failure { self.fail("Metal could not display the screen: \(failure)", token: submission.token) }
                if self.stopped { self.executor.stop() }
            }
        }
        guard mailbox.isCurrent(token) else {
            _ = presentations.completedGPU(submissionID)
            _ = presentations.presented(submissionID)
            completeDraw(); return
        }
        lastFrame = (frame, token)
        gpuBusy = true
        if statistics.update(
            token: token,
            { state in
                state.drawSubmissions &+= 1; state.lastPixelFormat = format; state.size = videoSize
                state.maxUnpresented = max(state.maxUnpresented, UInt64(presentations.outstanding))
            })
        {
            wakeUI()
        }
        schedulePresentationWatchdog()
        if targetPresentation != nil {
            // Display-link drawables require present() after GPU commits and
            // before the update deadline. Timed present variants assert.
            command.commit()
            drawable.present()
        } else {
            command.present(drawable)
            command.commit()
        }
    }
    private static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct Vertex { float4 position [[position]]; float2 uv; };
        vertex Vertex screenVertex(uint i [[vertex_id]], constant float4& geometry [[buffer(0)]]) {
            float2 positions[] = {float2(-1,1), float2(-1,-1), float2(1,1), float2(1,-1)};
            float2 coords[] = {float2(0,0), float2(0,1), float2(1,0), float2(1,1)};
            float2 uv = coords[i];
            switch (uint(geometry.z)) {
                case 1: uv = float2(uv.y, 1-uv.x); break;
                case 2: uv = 1-uv; break;
                case 3: uv = float2(1-uv.y, uv.x); break;
            }
            return {float4(positions[i]*geometry.xy, 0, 1), uv};
        }
        fragment float4 screenNV12(Vertex in [[stage_in]], texture2d<float> luma [[texture(0)]],
            texture2d<float> chroma [[texture(1)]], constant float4& c [[buffer(0)]],
            constant float4& range [[buffer(1)]]) {
            constexpr sampler sample(filter::linear, address::clamp_to_edge);
            float y = (luma.sample(sample, in.uv).r - range.y) * range.x;
            float2 uv = (chroma.sample(sample, in.uv).rg - range.w) * range.z;
            return float4(y+c.x*uv.y, y+c.y*uv.x+c.z*uv.y, y+c.w*uv.x, 1);
        }
        fragment float4 screenRGB(Vertex in [[stage_in]], texture2d<float> image [[texture(0)]]) {
            constexpr sampler sample(filter::linear, address::clamp_to_edge);
            return image.sample(sample, in.uv);
        }
        """
}
