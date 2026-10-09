#if os(iOS)
    import DieterAPI
    import DieterShared
    import Foundation
    import Observation
    import SharedCore
    import UIKit

    /// One screen view over the shared core's screen session (`session`),
    /// which owns the slice, the command queue, and every word the view
    /// shows. This adapter adds the shared touch input (trackpad, canvas,
    /// toolbar arming, keys and text) and the UIKit cursor image. Video
    /// renders natively: `CoreScreenMedia` decodes into `renderer`, which is
    /// attached under the view's scope before the slice is observed there.
    @MainActor
    @Observable
    final class IOSScreenController: IOSScreenCanvasController {
        let session: ScreenSessionModel
        private(set) var cursorImage: UIImage?
        /// The normalized host cursor position; the view adopts it unless a
        /// finger holds the cursor.
        private(set) var hostCursor = CGPoint(x: 0.5, y: 0.5)
        /// Bumped whenever the host reports a cursor position.
        private(set) var hostCursorRevision = 0

        /// The toolbar's one-shot right click and armed modifier bits, as the
        /// shared touch input holds them.
        private(set) var rightClickArmed = false
        private(set) var armedModifiers: Int32 = 0
        /// The canvas zoom, 1 when the desktop fits the view.
        private(set) var zoom = 1.0
        private(set) var fitted = true
        /// Bumped when a toolbar button changed the canvas, so the view redraws.
        private(set) var canvasRevision = 0

        /// Draws the decoded video; the input view embeds it.
        let renderer: IOSScreenVideoView
        /// The touch trackpad, canvas, toolbar arming, and key/text input of
        /// this view, as the shared core implements them. Main-thread confined.
        @ObservationIgnored private(set) lazy var touch = SharedTouchScreen(
            scope: session.scope, slop: 8, doubleTapSlop: 100, doubleTapTimeoutMillis: 300,
            sink: IOSScreenCommandSink { [weak self] command in self?.send(encoded: command) })
        @ObservationIgnored private var viewport: CGSize?
        @ObservationIgnored private var cursorData = Data()

        init(core: CoreClient, media: CoreScreenMedia?) {
            let renderer = IOSScreenVideoView(frame: .zero)
            self.renderer = renderer
            session = ScreenSessionModel(core: core, media: media, renderer: renderer, scopePrefix: "ios-screen")
            session.onFold = { [weak self] hadControl in self?.folded(hadControl: hadControl) }
        }

        var phase: String { session.phase }
        var phaseLabel: String { session.phaseLabel }
        var problem: String { session.problem }
        var active: Bool { session.active }
        var streaming: Bool { session.streaming }
        var failed: Bool { session.failed }
        /// The machine cannot share its screen now (permission or support).
        var blocked: Bool { session.blocked }
        var capabilities: Dieter_V1_RemoteDesktopCapabilities { session.capabilities }
        var sessionState: Dieter_V1_RemoteDesktopSessionState { session.sessionState }
        var preferences: ClientScreenPreferences { session.preferences }
        var routeLabel: String { session.routeLabel }
        var controlActive: Bool { session.controlActive }
        var canTransferControl: Bool { session.canTransferControl }
        var controlTransferring: Bool { session.controlTransferring }
        var controlError: String { session.controlError }
        var controlUnavailableReason: String { session.controlUnavailableReason }
        var codecFallbackReason: String { session.codecFallbackReason }
        var clipboardEnabled: Bool { session.clipboardEnabled }
        var clipboardError: String { session.clipboardError }
        var clipboardActionsEnabled: Bool { session.clipboardActionsEnabled }
        var latencyLabel: String { session.latencyLabel }
        var frameRates: [Int32] { session.frameRates }
        var cursor: ScreenCursorState { session.cursor }

        /// What the view says while not streaming, as the core words it for
        /// this phase and the machine's readiness to share.
        func waitingMessage(machine: ClientMachineEntry?) -> String {
            SharedRules.shared.screenWaitingMessage(
                phase: session.phase, problem: session.problem, hostReady: machine?.remoteDesktopReady ?? true,
                hostReason: machine?.remoteDesktopReason ?? "")
        }

        private func folded(hadControl: Bool) {
            // Losing control drops the gesture and everything armed.
            if hadControl, !session.controlActive {
                touch.touchesCancelled()
                syncArmed()
            }
            if cursorData != session.cursorImage {
                cursorData = session.cursorImage
                cursorImage = cursorData.isEmpty || cursorData.count > 262_144 ? nil : UIImage(data: cursorData)
            }
            let position = CGPoint(x: session.cursor.x, y: session.cursor.y)
            if hostCursor != position {
                hostCursor = position
                hostCursorRevision &+= 1
            }
        }

        // MARK: Session

        /// Opens a session with `daemonID`; an earlier one closes first.
        func connect(daemonID: String) { session.connect(daemonID: daemonID) }

        func disconnect() {
            touch.touchesCancelled()
            session.disconnect()
        }

        /// Closes the session and stops observing it; the view is done.
        func close() {
            touch.touchesCancelled()
            session.close()
        }

        /// The app went to the background (input is released and the host
        /// stops getting it) or returned (the session starts over at once).
        func setForeground(_ foreground: Bool) { session.setAsleep(!foreground) }

        // MARK: Toolbar and canvas

        func toggleRightClick() {
            touch.toggleRightClick()
            syncArmed()
        }

        /// Shift 1, Control 2, Option 4, Command 8.
        func toggleModifier(_ mask: Int32) {
            touch.toggleModifier(mask: mask)
            syncArmed()
        }

        /// A toolbar key, pressed with the armed modifiers.
        func press(hid: Int32) { touch.press(hid: hid) }

        /// Releases every held key and button on the host and disarms the toolbar.
        func releaseInput() { touch.releaseInput() }

        var minimumZoom: Double { touch.minimumZoom }
        var maximumZoom: Double { touch.maximumZoom }

        /// Zooms around the view's center.
        func zoom(by factor: Double) {
            guard let viewport else { return }
            touch.zoomBy(factor: factor, centerX: viewport.width / 2, centerY: viewport.height / 2)
            canvasRevision &+= 1
            canvasChanged()
        }

        /// Fits the desktop to the view again.
        func fit() {
            touch.fit()
            canvasRevision &+= 1
            canvasChanged()
        }

        /// The view moved or zoomed the canvas.
        func canvasChanged() {
            let zoom = touch.zoom
            let fitted = touch.isFitted
            if self.zoom != zoom { self.zoom = zoom }
            if self.fitted != fitted { self.fitted = fitted }
        }

        private func syncArmed() {
            let right = touch.rightClickArmed
            let modifiers = touch.armedModifiers
            if rightClickArmed != right { rightClickArmed = right }
            if armedModifiers != modifiers { armedModifiers = modifiers }
        }

        // MARK: Commands

        /// Takes or hands back control of the host.
        func transferControl(take: Bool) { session.transferControl(take: take) }

        /// Shows another of the host's displays.
        func selectDisplay(_ id: String) { session.setPreferences { $0.displayID = id } }

        func selectQuality(_ quality: Dieter_V1_RemoteDesktopQuality) {
            session.setPreferences { $0.quality = quality }
        }

        func selectCodec(_ codec: Dieter_V1_RemoteDesktopCodecPreference) {
            session.setPreferences { $0.codec = codec }
        }

        /// One of `frameRates`.
        func selectFrameRate(_ fps: Int32) { session.setPreferences { $0.maxFps = fps } }

        /// Asks the host for a fresh frame.
        func refresh() { session.refresh() }

        func setClipboardEnabled(_ on: Bool) { session.setClipboardEnabled(on) }

        /// "copy", "cut", or "paste" on the host.
        func performClipboard(_ operation: String) { session.performClipboard(operation) }

        /// The view's size in points; the core requests a stream to suit it.
        func setViewport(_ size: CGSize, scale: CGFloat) {
            viewport = size
            session.setViewport(size, scale: scale)
        }

        /// A command the shared touch input encoded.
        private func send(encoded: Data) {
            // Clicks, keys, text, and releases use up what the toolbar armed.
            syncArmed()
            session.send(encoded: encoded)
        }

        /// Waits for every command sent so far.
        func settle() async { await session.settle() }
    }

    /// Hands the commands shared touch input encodes to the controller, on
    /// the main thread where the input runs.
    private final class IOSScreenCommandSink: NSObject, SharedTouchScreenSink, Sendable {
        private let deliver: @MainActor @Sendable (Data) -> Void

        init(_ deliver: @escaping @MainActor @Sendable (Data) -> Void) {
            self.deliver = deliver
        }

        func send(command: Data) {
            let deliver = deliver
            MainActor.assumeIsolated { deliver(command) }
        }
    }
#endif
