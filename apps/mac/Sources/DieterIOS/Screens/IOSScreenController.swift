#if os(iOS)
    import DieterAPI
    import DieterShared
    import Foundation
    import Observation
    import SharedCore
    import UIKit

    /// The host cursor as the screen slice reports it: whether the host shows
    /// one, its image and size in host points, and its hotspot.
    struct IOSScreenCursor: Equatable {
        var visible = false
        var width = 0.0
        var height = 0.0
        var hotspotX = 0.0
        var hotspotY = 0.0
    }

    /// One screen view over the shared core's screen session. The core owns
    /// signaling, trust, the lease, recovery, codec fallback, input
    /// sequencing, clipboard sync, and display matching; this adapter folds
    /// `SLICE_SCREEN` for the view and dispatches the screen commands its
    /// buttons and the shared touch input produce. Video renders natively:
    /// `CoreScreenMedia` decodes into `renderer`, which is attached under the
    /// view's scope before the slice is observed there.
    @MainActor
    @Observable
    final class IOSScreenController {
        /// The core's phase name: "idle", "loading", "streaming", "failed", …
        private(set) var phase = "idle"
        /// The phase as status lines show it: "Not connected", "Live", …
        private(set) var phaseLabel = "Not connected"
        /// Why no session can run, or why it is reconnecting.
        private(set) var problem = ""
        /// The session is open or on its way.
        private(set) var active = false
        private(set) var capabilities = Dieter_V1_RemoteDesktopCapabilities()
        private(set) var sessionState = Dieter_V1_RemoteDesktopSessionState()
        private(set) var preferences = ClientScreenPreferences()
        /// The signaling route, e.g. "Gateway relay".
        private(set) var routeLabel = ""
        /// The media path the engine measured: "Direct media" or "Relayed media".
        private(set) var mediaRouteLabel = ""
        /// This client controls the host and may send input now.
        private(set) var controlActive = false
        private(set) var canTransferControl = false
        private(set) var controlTransferring = false
        private(set) var controlError = ""
        /// Why this client cannot take control of the live session; empty when it can.
        private(set) var controlUnavailableReason = ""
        private(set) var codecFallbackReason = ""
        private(set) var clipboardEnabled = true
        private(set) var clipboardError = ""
        /// Copy and paste can run now.
        private(set) var clipboardActionsEnabled = false
        /// The round trip, e.g. "12 ms RTT".
        private(set) var latencyLabel = ""
        /// The frame rates the host offers.
        private(set) var frameRates: [Int32] = []
        private(set) var cursor = IOSScreenCursor()
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

        var streaming: Bool { phase == "streaming" }
        var failed: Bool { phase == "failed" }
        /// The machine cannot share its screen now (permission or support).
        var blocked: Bool { phase == "permission_required" || phase == "unsupported" }

        /// What the view says while not streaming, as the core words it for
        /// this phase and the machine's readiness to share.
        func waitingMessage(machine: ClientMachineEntry?) -> String {
            SharedRules.shared.screenWaitingMessage(
                phase: phase, problem: problem, hostReady: machine?.remoteDesktopReady ?? true,
                hostReason: machine?.remoteDesktopReason ?? "")
        }

        /// Draws the decoded video; the input view embeds it.
        let renderer = IOSScreenVideoView(frame: .zero)
        /// The touch trackpad, canvas, toolbar arming, and key/text input of
        /// this view, as the shared core implements them. Main-thread confined.
        @ObservationIgnored private(set) lazy var touch = SharedTouchScreen(
            scope: scope, slop: 8, doubleTapSlop: 100, doubleTapTimeoutMillis: 300,
            sink: IOSScreenCommandSink { [weak self] command in self?.send(encoded: command) })
        @ObservationIgnored let scope = "ios-screen-\(UUID().uuidString.lowercased())"
        @ObservationIgnored private let core: CoreClient
        @ObservationIgnored private let media: CoreScreenMedia?
        @ObservationIgnored private var subscription: SliceSubscription?
        /// The latest command sent without waiting; later ones wait for it, so
        /// input reaches the core in the order UIKit delivered it.
        @ObservationIgnored private var queued: Task<Void, Never>?
        @ObservationIgnored private var viewport: CGSize?
        @ObservationIgnored private var backgrounded = false

        init(core: CoreClient, media: CoreScreenMedia?) {
            self.core = core
            self.media = media
        }

        // MARK: Session

        /// Opens a session with `daemonID`; an earlier one closes first.
        func connect(daemonID: String) {
            observe()
            if let viewport { sendViewport(viewport, scale: renderer.window?.screen.scale ?? 2) }
            send { $0.connect = .with { $0.daemonID = daemonID } }
        }

        func disconnect() {
            touch.touchesCancelled()
            mediaRouteLabel = ""
            send { $0.disconnect = ClientStep() }
        }

        /// Closes the session and stops observing it; the view is done.
        func close() {
            disconnect()
            subscription?.close()
            subscription = nil
            media?.detach(scope: scope)
        }

        /// The app went to the background (input is released and the host
        /// stops getting it) or returned (the session starts over at once).
        func setForeground(_ foreground: Bool) {
            if foreground {
                guard backgrounded else { return }
                backgrounded = false
                send { $0.resume = ClientStep() }
            } else {
                guard !backgrounded else { return }
                backgrounded = true
                send { $0.focused = .with { $0.on = false } }
                send { $0.sleep = ClientStep() }
            }
        }

        private func observe() {
            guard subscription == nil else { return }
            // The core creates this scope's media engine when the slice is
            // observed, so the renderer must be attached first.
            media?.attach(scope: scope, renderer: renderer) { [weak self] route in self?.mediaRouteLabel = route }
            subscription = SliceSubscription(client: core, slice: .screen, scope: scope) { [weak self] update in
                guard let self else { return }
                switch update.value {
                case .screen(let slice): self.fold(slice)
                case .failure(let failure):
                    self.phase = "failed"
                    self.problem = failure.message
                    self.active = false
                default: break
                }
            }
        }

        func fold(_ slice: ClientScreenSlice) {
            if phase != slice.phase { phase = slice.phase }
            if phaseLabel != slice.phaseLabel { phaseLabel = slice.phaseLabel }
            if problem != slice.problem { problem = slice.problem }
            if active != slice.active { active = slice.active }
            let capabilities = slice.hasCapabilities ? slice.capabilities : .init()
            if self.capabilities != capabilities { self.capabilities = capabilities }
            let state = slice.hasState ? slice.state : .init()
            if sessionState != state { sessionState = state }
            if preferences != slice.preferences { preferences = slice.preferences }
            if routeLabel != slice.routeLabel { routeLabel = slice.routeLabel }
            if !slice.active, !mediaRouteLabel.isEmpty { mediaRouteLabel = "" }
            if controlActive != slice.controlActive {
                // Losing control drops the gesture and everything armed.
                if !slice.controlActive { touch.touchesCancelled() }
                controlActive = slice.controlActive
            }
            if canTransferControl != slice.canTransferControl { canTransferControl = slice.canTransferControl }
            if controlTransferring != slice.controlTransferring { controlTransferring = slice.controlTransferring }
            if controlError != slice.controlError { controlError = slice.controlError }
            if controlUnavailableReason != slice.controlUnavailableReason {
                controlUnavailableReason = slice.controlUnavailableReason
            }
            if codecFallbackReason != slice.codecFallbackReason { codecFallbackReason = slice.codecFallbackReason }
            if clipboardEnabled != slice.clipboardEnabled { clipboardEnabled = slice.clipboardEnabled }
            if clipboardError != slice.clipboardError { clipboardError = slice.clipboardError }
            if clipboardActionsEnabled != slice.clipboardActionsEnabled {
                clipboardActionsEnabled = slice.clipboardActionsEnabled
            }
            if latencyLabel != slice.latencyLabel { latencyLabel = slice.latencyLabel }
            if frameRates != slice.frameRates { frameRates = slice.frameRates }
            if !slice.cursorImageUnchanged {
                cursorImage =
                    slice.cursorImage.isEmpty || slice.cursorImage.count > 262_144
                    ? nil : UIImage(data: slice.cursorImage)
            }
            let cursor = IOSScreenCursor(
                visible: slice.cursorVisible, width: slice.cursorWidth, height: slice.cursorHeight,
                hotspotX: slice.cursorHotspotX, hotspotY: slice.cursorHotspotY)
            if self.cursor != cursor { self.cursor = cursor }
            let position = CGPoint(x: slice.cursorX, y: slice.cursorY)
            if hostCursor != position {
                hostCursor = position
                hostCursorRevision &+= 1
            }
        }

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
        func transferControl(take: Bool) {
            guard canTransferControl, !controlTransferring else { return }
            send { $0.control = .with { $0.on = take } }
        }

        /// Shows another of the host's displays.
        func selectDisplay(_ id: String) { setPreferences { $0.displayID = id } }

        func selectQuality(_ quality: Dieter_V1_RemoteDesktopQuality) { setPreferences { $0.quality = quality } }

        func selectCodec(_ codec: Dieter_V1_RemoteDesktopCodecPreference) { setPreferences { $0.codec = codec } }

        /// One of `frameRates`.
        func selectFrameRate(_ fps: Int32) { setPreferences { $0.maxFps = fps } }

        /// Asks the host for a fresh frame.
        func refresh() { send { $0.refresh = ClientStep() } }

        func setClipboardEnabled(_ on: Bool) { send { $0.clipboardEnabled = .with { $0.on = on } } }

        /// "copy", "cut", or "paste" on the host.
        func performClipboard(_ operation: String) { send { $0.clipboard = .with { $0.operation = operation } } }

        /// The view's size in points; the core requests a stream to suit it.
        func setViewport(_ size: CGSize, scale: CGFloat) {
            guard size.width > 0, size.height > 0, scale > 0, viewport != size else { return }
            viewport = size
            sendViewport(size, scale: scale)
        }

        private func setPreferences(_ change: (inout ClientScreenPreferences) -> Void) {
            var wanted = preferences
            change(&wanted)
            send { $0.preferences = wanted }
        }

        private func sendViewport(_ size: CGSize, scale: CGFloat) {
            send {
                $0.viewport = .with {
                    $0.widthPoints = Double(size.width)
                    $0.heightPoints = Double(size.height)
                    $0.scale = Double(scale)
                }
            }
        }

        /// A command the shared touch input encoded.
        private func send(encoded: Data) {
            // Clicks, keys, text, and releases use up what the toolbar armed.
            syncArmed()
            guard let screen = try? ClientScreenCommand(serializedBytes: encoded) else { return }
            dispatch(screen)
        }

        private func send(_ build: (inout ClientScreenCommand) -> Void) {
            var screen = ClientScreenCommand()
            screen.scope = scope
            build(&screen)
            dispatch(screen)
        }

        /// Sends a screen command after those sent before, without waiting.
        /// The core has no screen for this view until it is observed.
        private func dispatch(_ screen: ClientScreenCommand) {
            guard subscription != nil else { return }
            let core = core
            let command = ClientCommand.with { $0.screen = screen }
            let previous = queued
            queued = Task {
                await previous?.value
                _ = try? await core.dispatch(command)
            }
        }

        /// Waits for every command sent so far.
        func settle() async {
            await queued?.value
        }
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
