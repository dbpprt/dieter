import AppKit
import CoreVideo
@preconcurrency import MetalKit
@preconcurrency import WebRTC

// Keep decoded IOSurfaces on the GPU. The bundled RTCMTLNSVideoView converts
// every frame to CPU I420 and runs a 30 Hz timer, even for a 60 Hz stream.
@MainActor
final class RemoteDesktopMetalView: NSView, RTCVideoRenderer, MTKViewDelegate {
    weak var delegate: (any RTCVideoViewDelegate)?
    var onFramePresented: (@MainActor (RTCVideoFrame) -> Void)?
    var onPresentationTiming: (@MainActor (RTCVideoFrame, Double) -> Void)?
    private(set) var totalRenderMilliseconds: Double = 0
    private(set) var timedPresentations: UInt64 = 0
    var onFailure: (@MainActor (String) -> Void)?
    private(set) var initializationFailure: String?
    private(set) var framesPresented: UInt64 = 0
    private(set) var drawSubmissions: UInt64 = 0
    private(set) var lastPixelFormat: OSType = 0
    private var lastPresentedTimestamp: Int32?
    private let metal = MTKView(frame: .zero)
    private var commandQueue: (any MTLCommandQueue)?
    private var nv12Pipeline: (any MTLRenderPipelineState)?
    private var rgbPipeline: (any MTLRenderPipelineState)?
    private var textureCache: CVMetalTextureCache?
    private var lastFrame: RTCVideoFrame?
    private var videoSize = CGSize.zero
    private var previousBounds = CGSize.zero
    nonisolated private let mailbox = RemoteDesktopRenderMailbox()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        guard let device = MTLCreateSystemDefaultDevice() else {
            initializationFailure = "Metal is unavailable on this Mac."; return
        }
        metal.device = device
        metal.colorPixelFormat = .bgra8Unorm
        metal.clearColor = MTLClearColorMake(0, 0, 0, 1)
        metal.isPaused = true
        metal.enableSetNeedsDisplay = false
        metal.framebufferOnly = true
        metal.delegate = self
        if let layer = metal.layer as? CAMetalLayer {
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            layer.maximumDrawableCount = 2
        }
        addSubview(metal)
        do {
            commandQueue = device.makeCommandQueue()
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            func pipeline(_ fragment: String) throws -> any MTLRenderPipelineState {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "screenVertex")
                descriptor.fragmentFunction = library.makeFunction(name: fragment)
                descriptor.colorAttachments[0].pixelFormat = metal.colorPixelFormat
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

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        metal.frame = bounds
        if previousBounds != bounds.size {
            previousBounds = bounds.size
            if let lastFrame { renderFrame(lastFrame) }
        }
    }

    func reset() {
        mailbox.reset()
        lastFrame = nil
        lastPresentedTimestamp = nil
        framesPresented = 0
        totalRenderMilliseconds = 0; timedPresentations = 0
        drawSubmissions = 0
        videoSize = .zero
        // Hide the previous session's retained drawable immediately.
        metal.isHidden = true
    }

    nonisolated func setSize(_ size: CGSize) {
        Task { @MainActor [weak self] in self?.updateSize(size) }
    }

    func decodeHandler() -> @Sendable (RTCVideoFrame) -> Void {
        let token = mailbox.currentToken
        return { [weak self, mailbox] frame in
            guard let self, mailbox.offer(frame, expectedToken: token) else { return }
            Task { @MainActor [weak self] in self?.drawPendingFrame() }
        }
    }

    nonisolated func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, mailbox.offer(frame) else { return }
        Task { @MainActor [weak self] in self?.drawPendingFrame() }
    }

    private func drawPendingFrame() {
        guard mailbox.hasPending else { completeDraw(); return }
        metal.isHidden = false
        metal.draw()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, let lastFrame { renderFrame(lastFrame) }
    }

    private func updateSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != videoSize else { return }
        videoSize = size
        delegate?.videoView(self, didChangeVideoSize: size)
    }

    private func completeDraw() {
        if mailbox.complete() { Task { @MainActor [weak self] in self?.drawPendingFrame() } }
    }

    func draw(in view: MTKView) {
        // nextDrawable may wait for the compositor. Select the latest frame
        // AFTER that wait, allowing decoder arrivals to replace stale work.
        guard bounds.width > 0, bounds.height > 0, let drawable = view.currentDrawable,
            let descriptor = view.currentRenderPassDescriptor
        else {
            _ = mailbox.take(); completeDraw(); return
        }
        guard let (frame, token, arrivedAt) = mailbox.take() else { completeDraw(); return }
        guard initializationFailure == nil, let queue = commandQueue, let cache = textureCache,
            let native = frame.buffer as? RTCCVPixelBuffer
        else {
            completeDraw()
            onFailure?(initializationFailure ?? "The screen decoder did not supply a native pixel buffer.")
            return
        }
        let pixel = native.pixelBuffer
        let format = CVPixelBufferGetPixelFormatType(pixel)
        let isNV12 =
            format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard isNV12 || format == kCVPixelFormatType_32BGRA else {
            completeDraw(); onFailure?("The screen decoder supplied an unsupported pixel format."); return
        }
        let rotated = frame.rotation == ._90 || frame.rotation == ._270
        let size = CGSize(
            width: CGFloat(rotated ? frame.height : frame.width), height: CGFloat(rotated ? frame.width : frame.height))
        updateSize(size)
        lastFrame = frame
        lastPixelFormat = format
        view.isHidden = false
        guard let command = queue.makeCommandBuffer(),
            let pipeline = isNV12 ? nv12Pipeline : rgbPipeline
        else { completeDraw(); return }
        var retained: [CVMetalTexture] = []
        func texture(_ plane: Int, _ format: MTLPixelFormat) -> (any MTLTexture)? {
            var reference: CVMetalTexture?
            let planar = CVPixelBufferIsPlanar(pixel)
            let width = planar ? CVPixelBufferGetWidthOfPlane(pixel, plane) : CVPixelBufferGetWidth(pixel)
            let height = planar ? CVPixelBufferGetHeightOfPlane(pixel, plane) : CVPixelBufferGetHeight(pixel)
            guard
                CVMetalTextureCacheCreateTextureFromImage(
                    nil, cache, pixel, nil, format, width, height,
                    plane, &reference) == kCVReturnSuccess, let reference
            else { return nil }
            retained.append(reference)
            return CVMetalTextureGetTexture(reference)
        }
        guard let first = texture(0, isNV12 ? .r8Unorm : .bgra8Unorm) else {
            completeDraw(); onFailure?("The screen pixel buffer could not be mapped into Metal."); return
        }
        let chroma = isNV12 ? texture(1, .rg8Unorm) : nil
        guard !isNV12 || chroma != nil, let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
            completeDraw(); onFailure?("The screen texture could not be rendered."); return
        }
        let aspect = size.width / size.height, surfaceAspect = bounds.width / bounds.height
        var geometry = SIMD4<Float>(
            Float(min(1, aspect / surfaceAspect)), Float(min(1, surfaceAspect / aspect)),
            Float(frame.rotation.rawValue / 90), 0)
        let matrix = CVBufferCopyAttachment(pixel, kCVImageBufferYCbCrMatrixKey, nil) as? String
        var coefficients =
            matrix == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
            ? SIMD4<Float>(1.402, -0.344136, -0.714136, 1.772)
            : SIMD4<Float>(1.5748, -0.187324, -0.468124, 1.8556)
        let limited = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        var range = SIMD4<Float>(
            limited ? 255.0 / 219 : 1, limited ? 16.0 / 255 : 0,
            limited ? 255.0 / 224 : 1, 128.0 / 255)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&geometry, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentTexture(first, index: 0)
        if let chroma { encoder.setFragmentTexture(chroma, index: 1) }
        encoder.setFragmentBytes(&coefficients, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentBytes(&range, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        let submission = RemoteDesktopMetalSubmission(frame: frame, textures: retained, token: token)
        drawable.addPresentedHandler { [weak self, submission] drawable in
            // Read the hardware presentation timestamp before hopping to MainActor;
            // callback scheduling delay is not display latency.
            let presentedAt = drawable.presentedTime
            Task { @MainActor [weak self] in
                guard let self, self.mailbox.isCurrent(submission.token) else { return }
                if self.lastPresentedTimestamp != submission.frame.timeStamp {
                    self.framesPresented &+= 1
                    self.lastPresentedTimestamp = submission.frame.timeStamp
                    if presentedAt >= arrivedAt && presentedAt > 0 {
                        self.totalRenderMilliseconds += (presentedAt - arrivedAt) * 1000
                        self.timedPresentations &+= 1
                        self.onPresentationTiming?(submission.frame, presentedAt)
                    }
                }
                self.onFramePresented?(submission.frame)
            }
        }
        command.addCompletedHandler { [weak self, submission] command in
            // Retain the IOSurface and CVMetalTexture wrappers through GPU use.
            _ = submission
            let failure = command.error?.localizedDescription
            Task { @MainActor [weak self] in
                self?.completeDraw()
                if let failure, let self, self.mailbox.isCurrent(submission.token) {
                    self.onFailure?("Metal could not display the screen: \(failure)")
                }
            }
        }
        drawSubmissions &+= 1
        command.present(drawable)
        command.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

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

private final class RemoteDesktopMetalSubmission: @unchecked Sendable {
    let frame: RTCVideoFrame
    let textures: [CVMetalTexture]
    let token: UInt64
    init(frame: RTCVideoFrame, textures: [CVMetalTexture], token: UInt64) {
        self.frame = frame; self.textures = textures; self.token = token
    }
}

// One GPU submission plus one replaceable decoded frame. No per-frame dispatch
// queue and no idle display timer. Reset invalidates late presentation callbacks.
private final class RemoteDesktopRenderMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: RTCVideoFrame?
    private var arrivedAt: Double = 0
    private var busy = false
    private var token: UInt64 = 0
    var hasPending: Bool { lock.lock(); defer { lock.unlock() }; return pending != nil }
    var currentToken: UInt64 { lock.lock(); defer { lock.unlock() }; return token }
    func offer(_ frame: RTCVideoFrame, expectedToken: UInt64? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let expectedToken, expectedToken != token { return false }
        pending = frame
        arrivedAt = CACurrentMediaTime()
        if busy { return false }
        busy = true; return true
    }
    func take() -> (RTCVideoFrame, UInt64, Double)? {
        lock.lock(); defer { lock.unlock() }
        guard let pending else { return nil }
        self.pending = nil; return (pending, token, arrivedAt)
    }
    func complete() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if pending != nil { return true }
        busy = false; return false
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        token &+= 1; pending = nil
    }
    func isCurrent(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return token == self.token
    }
}
