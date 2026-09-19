import AppKit
import CoreVideo
@preconcurrency import MetalKit
@preconcurrency import WebRTC

// AppKit owns layout and input coordinates. Decoded IOSurfaces, drawable waits,
// GPU work and presentation timing belong to the independent render executor.
@MainActor
final class RemoteDesktopMetalView: NSView, RTCVideoRenderer {
    weak var delegate: (any RTCVideoViewDelegate)? {
        didSet {
            if videoSize.width > 0, videoSize.height > 0 {
                delegate?.videoView(self, didChangeVideoSize: videoSize)
            }
        }
    }
    var onFramePresented: (@MainActor (RTCVideoFrame) -> Void)?
    var onPresentationTiming: (@MainActor (RTCVideoFrame, Double) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var totalRenderMilliseconds: Double { renderer.snapshot.totalRenderMilliseconds }
    var latePresentations: UInt64 { renderer.snapshot.latePresentations }
    var timedPresentations: UInt64 { renderer.snapshot.timedPresentations }
    var framesPresented: UInt64 { renderer.snapshot.framesPresented }
    var drawSubmissions: UInt64 { renderer.snapshot.drawSubmissions }
    var lastPixelFormat: OSType { renderer.snapshot.lastPixelFormat }
    var initializationFailure: String? { renderer.initializationFailure }
    var presentationMode: RemoteDesktopPresentationMode { renderer.mode }
    var renderTrace: [RemoteDesktopRenderTraceRecord] { renderer.trace.snapshot }
    var maxUnpresented: UInt64 { renderer.snapshot.maxUnpresented }
    var presentationTimeouts: UInt64 { renderer.snapshot.presentationTimeouts }
    private let surface = NSView(frame: .zero)
    private var videoSize = CGSize.zero
    nonisolated private let renderer: RemoteDesktopMetalRenderer

    override init(frame: NSRect) {
        let relay = RemoteDesktopRenderRelay()
        let metal = CAMetalLayer()
        renderer = RemoteDesktopMetalRenderer(layer: metal, mode: .configured) { relay.wake() }
        super.init(frame: frame)
        relay.view = self
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        surface.wantsLayer = true
        surface.layer = metal
        surface.isHidden = true
        addSubview(surface)
    }

    required init?(coder: NSCoder) { nil }
    deinit { renderer.shutdown() }

    override func layout() { super.layout(); updateSurface() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateSurface() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateSurface() }

    private func updateSurface() {
        surface.frame = backingAlignedRect(bounds, options: .alignAllEdgesNearest)
        renderer.resize(pixelSize: drawablePixelSize, scale: window?.backingScaleFactor ?? 1, attached: window != nil)
    }

    var drawablePixelSize: CGSize {
        let backing = surface.convertToBacking(surface.bounds)
        return CGSize(width: backing.width.rounded(), height: backing.height.rounded())
    }

    func contentRect(videoSize: CGSize) -> CGRect {
        let backing = surface.convertToBacking(surface.bounds)
        let pixels = RemoteDesktopVideoGeometry.contentRect(pixelSize: drawablePixelSize, videoSize: videoSize)
            .offsetBy(dx: backing.minX, dy: backing.minY)
        return convert(surface.convertFromBacking(pixels), from: surface)
    }

    func reset() {
        renderer.reset()
        videoSize = .zero
        surface.isHidden = true
    }

    nonisolated func setSize(_ size: CGSize) {
        Task { @MainActor [weak self] in self?.updateSize(size) }
    }

    func decodeHandler() -> @Sendable (RTCVideoFrame) -> Void { renderer.decodeHandler() }
    nonisolated func renderFrame(_ frame: RTCVideoFrame?) { if let frame { renderer.offer(frame) } }

    private func updateSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != videoSize else { return }
        videoSize = size
        delegate?.videoView(self, didChangeVideoSize: size)
    }

    fileprivate func rendererUpdated() {
        let update = renderer.consumeUpdate()
        guard renderer.isCurrent(update.token) else { return }
        updateSize(update.size)
        if update.drawSubmissions > 0, surface.isHidden {
            surface.isHidden = false
            // The initial GPU submission may complete while the old session's
            // surface is still hidden. Commit visibility and redraw that frame
            // so a static desktop gets a real presentation timestamp as well.
            CATransaction.flush()
            renderer.redraw()
        }
        if let failure = update.failure { onFailure?(failure) }
        if let presentation = update.presentation {
            if presentation.presentedAt > 0 {
                onPresentationTiming?(presentation.frame, presentation.presentedAt)
            }
            onFramePresented?(presentation.frame)
        }
    }
}

private final class RemoteDesktopRenderRelay: Sendable {
    @MainActor weak var view: RemoteDesktopMetalView?
    nonisolated func wake() { Task { @MainActor [weak self] in self?.view?.rendererUpdated() } }
}
