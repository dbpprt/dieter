import CoreGraphics
import DieterAPI
import Foundation
import Observation

/// One screen view's session over the shared core's screen surface. The core
/// owns signaling, trust, the lease, recovery, codec fallback, input
/// sequencing, clipboard sync, display matching, and every word the view
/// shows; this model observes the view's scope, keeps what the slice says in
/// separately observed properties (cursor moves redraw only the cursor), and
/// sends commands in the order the platform delivered them. Platform input
/// (AppKit events, touches) is mapped by the app and sent through `send`.
@MainActor
@Observable
package final class ScreenSessionModel {
    /// The core's phase name: "idle", "loading", "streaming", "failed", …
    package private(set) var phase = "idle"
    /// The phase as status lines show it: "Not connected", "Live", …
    package private(set) var phaseLabel = "Not connected"
    /// Why no session can run, or why it is reconnecting; or why the surface could not open.
    package private(set) var problem = ""
    /// The session is open or on its way.
    package private(set) var active = false
    package private(set) var streaming = false
    /// The machine cannot share its screen: permission or support is missing.
    package private(set) var blocked = false
    package private(set) var failed = false
    package private(set) var tone: ClientTone = .neutral
    /// "Connected · Control", or the phase.
    package private(set) var statusLine = "Not connected"
    /// "1920 × 1080 · H264 · 60 fps · Direct media" while streaming.
    package private(set) var metadata = ""
    /// "Direct media", "Relayed media", or empty until known.
    package private(set) var mediaRoute = ""
    /// The connection details, one line each.
    package private(set) var details: [String] = []
    /// "Control" or "View only".
    package private(set) var controlLabel = "View only"
    /// "2 viewers · Pixel controls", or empty.
    package private(set) var viewersLabel = ""
    package private(set) var capabilities = Dieter_V1_RemoteDesktopCapabilities()
    package private(set) var sessionState = Dieter_V1_RemoteDesktopSessionState()
    package private(set) var preferences = ClientScreenPreferences()
    /// The signaling route, e.g. "Gateway relay".
    package private(set) var routeLabel = ""
    /// This client controls the host and may send input now.
    package private(set) var controlActive = false
    package private(set) var canTransferControl = false
    package private(set) var controlTransferring = false
    package private(set) var controlError = ""
    /// Why this client cannot take control of the live session; empty when it can.
    package private(set) var controlUnavailableReason = ""
    package private(set) var codecFallbackReason = ""
    package private(set) var clipboardEnabled = true
    package private(set) var clipboardError = ""
    package private(set) var clipboardBusy = false
    package private(set) var clipboardOperations = 0
    /// Copy and paste can run now.
    package private(set) var clipboardActionsEnabled = false
    /// The round trip, e.g. "12 ms RTT".
    package private(set) var latencyLabel = ""
    /// The frame rates the host offers.
    package private(set) var frameRates: [Int32] = []
    /// Resolution matching while holding control.
    package private(set) var displayStatus = ""
    package private(set) var cursor = ScreenCursorState()
    /// The host cursor image (PNG), replaced only when the host sends a new one.
    package private(set) var cursorImage = Data()

    /// Called after each folded slice, with the control state it had before.
    @ObservationIgnored package var onFold: (_ hadControl: Bool) -> Void = { _ in }

    @ObservationIgnored package let scope: String
    @ObservationIgnored private let core: CoreClient?
    @ObservationIgnored private let media: CoreScreenMedia?
    @ObservationIgnored private let renderer: any ScreenRenderer
    @ObservationIgnored private var subscription: SliceSubscription?
    /// The latest command sent without waiting; later ones wait for it, so
    /// input reaches the core in the order the platform delivered it.
    @ObservationIgnored private var queued: Task<Void, Never>?
    @ObservationIgnored private var viewport: (size: CGSize, scale: CGFloat)?
    @ObservationIgnored private var asleep = false

    /// `scopePrefix` names the view kind; each model owns its own surface.
    package init(core: CoreClient?, media: CoreScreenMedia?, renderer: any ScreenRenderer, scopePrefix: String) {
        self.core = core
        self.media = media
        self.renderer = renderer
        scope = "\(scopePrefix)-\(UUID().uuidString.lowercased())"
    }

    /// The model observes its surface, so commands reach the core.
    package var observing: Bool { subscription != nil }

    // MARK: Session

    /// Opens a session with `daemonID`, asking for `preferences` when given;
    /// an earlier session closes first.
    package func connect(daemonID: String, preferences: ClientScreenPreferences? = nil) {
        observe()
        if let preferences { send { $0.preferences = preferences } }
        if let viewport { sendViewport(viewport.size, scale: viewport.scale) }
        send { $0.connect = .with { $0.daemonID = daemonID } }
    }

    package func disconnect() {
        send { $0.disconnect = ClientStep() }
    }

    /// Closes the session and stops observing it; the view is done.
    package func close() {
        disconnect()
        subscription?.close()
        subscription = nil
        media?.detach(scope: scope)
    }

    /// The input view holds keyboard focus in an active window; the core only
    /// sends input, and syncs the clipboard, while it does.
    package func setFocused(_ on: Bool) {
        send { $0.focused = .with { $0.on = on } }
    }

    /// The device sleeps or the app leaves the foreground (input is released
    /// and the session pauses), or it returns (the session resumes at once).
    package func setAsleep(_ asleep: Bool) {
        guard self.asleep != asleep else { return }
        self.asleep = asleep
        if asleep {
            setFocused(false)
            send { $0.sleep = ClientStep() }
        } else {
            send { $0.resume = ClientStep() }
        }
    }

    /// Takes or hands back control of the host.
    package func transferControl(take: Bool) {
        guard canTransferControl, !controlTransferring else { return }
        send { $0.control = .with { $0.on = take } }
    }

    /// Changes the stream the session asks for: display, quality, codec, or frame rate.
    package func setPreferences(_ change: (inout ClientScreenPreferences) -> Void) {
        var wanted = preferences
        change(&wanted)
        send { $0.preferences = wanted }
    }

    /// Asks the host for a fresh frame.
    package func refresh() { send { $0.refresh = ClientStep() } }

    package func setClipboardEnabled(_ on: Bool) { send { $0.clipboardEnabled = .with { $0.on = on } } }

    /// "copy", "cut", or "paste" on the host.
    package func performClipboard(_ operation: String) { send { $0.clipboard = .with { $0.operation = operation } } }

    /// Releases every held key and button on the host.
    package func releaseInput() { send { $0.releaseInput = ClientStep() } }

    /// Matches the host display to this screen while controlling it; nil stops.
    package func matchDisplay(width: Double, height: Double, scale: Double, refresh: Double) {
        send {
            $0.matchDisplay = .with {
                $0.width = width
                $0.height = height
                $0.scale = scale
                $0.refresh = refresh
            }
        }
    }

    package func stopMatchingDisplay() { send { $0.matchDisplay = ClientScreenDisplayTarget() } }

    /// The view's size in points; the core requests a stream to suit it.
    package func setViewport(_ size: CGSize, scale: CGFloat) {
        guard size.width > 0, size.height > 0, scale > 0 else { return }
        if let viewport, viewport.size == size, viewport.scale == scale { return }
        viewport = (size, scale)
        sendViewport(size, scale: scale)
    }

    // MARK: Slice

    private func observe() {
        guard subscription == nil, let core else { return }
        // The core creates this scope's media engine when the slice is
        // observed, so the renderer must be attached first.
        media?.attach(scope: scope, renderer: renderer)
        subscription = SliceSubscription(client: core, slice: .screen, scope: scope) { [weak self] update in
            guard let self else { return }
            switch update.value {
            case .screen(let slice): self.fold(slice)
            case .failure(let failure): self.fail(failure.message)
            default: break
            }
        }
    }

    /// The surface could not open: the view shows why.
    private func fail(_ message: String) {
        var slice = ClientScreenSlice()
        slice.phase = "failed"
        slice.phaseLabel = "Connection failed"
        slice.statusLine = "Connection failed"
        slice.problem = message
        slice.failed = true
        slice.tone = .danger
        fold(slice)
    }

    /// The last slice folded; UI fixtures change it and fold it back.
    @ObservationIgnored package private(set) var lastSlice = ClientScreenSlice()

    package func fold(_ slice: ClientScreenSlice) {
        lastSlice = slice
        let hadControl = controlActive
        set(\.phase, slice.phase)
        set(\.phaseLabel, slice.phaseLabel)
        set(\.problem, slice.problem)
        set(\.active, slice.active)
        set(\.streaming, slice.streaming)
        set(\.blocked, slice.blocked)
        set(\.failed, slice.failed)
        set(\.tone, slice.tone)
        set(\.statusLine, slice.statusLine)
        set(\.metadata, slice.metadata)
        set(\.mediaRoute, slice.mediaRoute)
        set(\.details, slice.details)
        set(\.controlLabel, slice.controlLabel)
        set(\.viewersLabel, slice.viewersLabel)
        set(\.capabilities, slice.hasCapabilities ? slice.capabilities : .init())
        set(\.sessionState, slice.hasState ? slice.state : .init())
        set(\.preferences, slice.preferences)
        set(\.routeLabel, slice.routeLabel)
        set(\.controlActive, slice.controlActive)
        set(\.canTransferControl, slice.canTransferControl)
        set(\.controlTransferring, slice.controlTransferring)
        set(\.controlError, slice.controlError)
        set(\.controlUnavailableReason, slice.controlUnavailableReason)
        set(\.codecFallbackReason, slice.codecFallbackReason)
        set(\.clipboardEnabled, slice.clipboardEnabled)
        set(\.clipboardError, slice.clipboardError)
        set(\.clipboardBusy, slice.clipboardBusy)
        set(\.clipboardOperations, Int(slice.clipboardOperations))
        set(\.clipboardActionsEnabled, slice.clipboardActionsEnabled)
        set(\.latencyLabel, slice.latencyLabel)
        set(\.frameRates, slice.frameRates)
        set(\.displayStatus, slice.displayStatus)
        set(\.cursor, ScreenCursorState(slice))
        if !slice.cursorImageUnchanged { set(\.cursorImage, slice.cursorImage) }
        onFold(hadControl)
    }

    /// Assigns only changes, so views reading other properties stay put.
    private func set<Value: Equatable>(_ key: ReferenceWritableKeyPath<ScreenSessionModel, Value>, _ value: Value) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    // MARK: Commands

    private func sendViewport(_ size: CGSize, scale: CGFloat) {
        send {
            $0.viewport = .with {
                $0.widthPoints = Double(size.width)
                $0.heightPoints = Double(size.height)
                $0.scale = Double(scale)
            }
        }
    }

    /// Sends a screen command after those sent before, without waiting.
    package func send(_ build: (inout ClientScreenCommand) -> Void) {
        var screen = ClientScreenCommand()
        screen.scope = scope
        build(&screen)
        dispatch(screen)
    }

    /// Sends a screen command the shared touch input encoded.
    package func send(encoded: Data) {
        guard let screen = try? ClientScreenCommand(serializedBytes: encoded) else { return }
        dispatch(screen)
    }

    /// The core has no screen for this view until it is observed.
    private func dispatch(_ screen: ClientScreenCommand) {
        guard let core, subscription != nil else { return }
        let command = ClientCommand.with { $0.screen = screen }
        let previous = queued
        queued = Task {
            await previous?.value
            _ = try? await core.dispatch(command)
        }
    }

    /// Waits for every command sent so far (tests and teardown).
    package func settle() async {
        await queued?.value
    }
}
