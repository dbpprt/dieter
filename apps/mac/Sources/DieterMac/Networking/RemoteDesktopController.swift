import AppKit
import DieterAPI
import DieterShared
import DieterTransport
import Foundation
import Observation
import SharedCore

enum RemoteDesktopPhase: Equatable, Sendable {
    case idle
    case loading
    case permissionRequired(String)
    case unsupported(String)
    case connecting
    case waitingForHostApproval
    case streaming
    case reconnecting
    case failed(String)

    /// The core's phase name and the reason it carries.
    init(core phase: String, problem: String) {
        switch phase {
        case "loading": self = .loading
        case "permission_required": self = .permissionRequired(problem)
        case "unsupported": self = .unsupported(problem)
        case "connecting": self = .connecting
        case "waiting_for_host_approval": self = .waitingForHostApproval
        case "streaming": self = .streaming
        case "reconnecting": self = .reconnecting
        case "failed": self = .failed(problem)
        default: self = .idle
        }
    }
}

extension RemoteDesktopPhase {
    /// The core's phase name and the reason it carries.
    var core: (phase: String, problem: String) {
        switch self {
        case .idle: ("idle", "")
        case .loading: ("loading", "")
        case .permissionRequired(let reason): ("permission_required", reason)
        case .unsupported(let reason): ("unsupported", reason)
        case .connecting: ("connecting", "")
        case .waitingForHostApproval: ("waiting_for_host_approval", "")
        case .streaming: ("streaming", "")
        case .reconnecting: ("reconnecting", "")
        case .failed(let message): ("failed", message)
        }
    }

    /// What a screen view says in this phase while not streaming, as the core
    /// words it, given whether the host can share (`hostReady`, `hostReason`).
    func waitingMessage(hostReady: Bool, hostReason: String) -> String {
        let core = core
        return SharedRules.shared.screenWaitingMessage(
            phase: core.phase, problem: core.problem, hostReady: hostReady, hostReason: hostReason)
    }
}

/// The host cursor the core reports: whether it shows and where, normalized
/// to the shared display.
struct RemoteDesktopCursorState: Equatable {
    var visible = false
    var x = 0.5
    var y = 0.5
}

/// One screen view over the shared core's screen session. The core owns
/// signaling, trust, the lease, recovery, codec fallback, input sequencing,
/// clipboard sync, and display matching; this adapter turns AppKit input into
/// screen commands and folds the screen slice into what the views read. Video
/// renders natively: `CoreScreenMedia` decodes into `renderer`.
@MainActor
@Observable
final class RemoteDesktopController {
    var phase: RemoteDesktopPhase = .idle
    /// The phase as status lines show it, from the core: "Not connected", "Live", …
    private(set) var phaseLabel = "Not connected"
    /// The session is open or on its way: Disconnect, not Connect (fixtures set it).
    var active = false
    var capabilities = Dieter_V1_RemoteDesktopCapabilities()
    var routeLabel = ""
    var machineName = ""
    var errorMessage: String?
    var sessionState = Dieter_V1_RemoteDesktopSessionState()
    var mediaRouteLabel = "Negotiating media"
    var remoteCursor: NSCursor = .arrow
    var remoteCursorState = RemoteDesktopCursorState()
    var clipboardError = ""
    private(set) var clipboardEnabled = true
    private(set) var clipboardBusy = false
    private(set) var clipboardOperations = 0
    /// The input view holds keyboard focus in an active window; the core only
    /// sends input, and syncs the clipboard, while it does.
    var inputFocused = false {
        didSet {
            guard inputFocused != oldValue else { return }
            let on = inputFocused
            send { $0.focused = .with { $0.on = on } }
        }
    }
    var textInputMode = false
    private(set) var quality: Dieter_V1_RemoteDesktopQuality = .auto
    var preferredMaxFPS: Int32 = 60
    var codecPreference: Dieter_V1_RemoteDesktopCodecPreference = .h264
    private(set) var codecFallbackReason = ""
    /// The frame rates the host offers, from the core.
    private(set) var frameRates: [Int32] = []
    /// This client controls the host and may send input now; folded from the
    /// slice (fixtures set it directly).
    var controlActive = false { didSet { if oldValue != controlActive { onCursorChange() } } }
    private(set) var canTransferControl = false
    private(set) var controlTransferPending = false
    private(set) var controlTransferError = ""
    /// Why this client cannot take control of a live session; empty when it can.
    private(set) var controlUnavailableReason = ""
    /// Copy and paste can run now: control, a shared clipboard, nothing in flight.
    private(set) var clipboardActionsEnabled = false
    /// The round trip as the status bar shows it, e.g. "12 ms RTT".
    private(set) var latencyLabel = ""
    var keyboardCaptureStatus = ""
    private(set) var displayMatchingStatus = ""
    @ObservationIgnored var onCursorChange: @MainActor () -> Void = {}
    @ObservationIgnored var onUserActivity: @MainActor () -> Void = {}
    @ObservationIgnored var onSystemSleep: (() -> Void)?
    private(set) var systemSleeping = false

    let renderer = RemoteDesktopMetalView(frame: .zero)
    @ObservationIgnored private let core: CoreClient?
    @ObservationIgnored private let media: CoreScreenMedia?
    @ObservationIgnored let scope = "screen-\(UUID().uuidString)"
    @ObservationIgnored private var subscription: SliceSubscription?
    /// The latest command sent without waiting; later ones wait for it, so
    /// input reaches the core in the order AppKit delivered it.
    @ObservationIgnored private var queued: Task<Void, Never>?
    @ObservationIgnored private var viewport: CGSize?
    @ObservationIgnored private var displayID = ""
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var sleepObserver: NSObjectProtocol?

    init(core: CoreClient? = nil, media: CoreScreenMedia? = nil) {
        self.core = core
        self.media = media
    }

    /// Opens a session with `daemonID`; an earlier one closes first.
    func connect(daemonID: String, machineName: String) {
        self.machineName = machineName
        errorMessage = nil
        observe()
        installPowerObservers()
        sendPreferences()
        if let viewport { sendViewport(viewport) }
        send { $0.connect = .with { $0.daemonID = daemonID } }
    }

    func disconnect() {
        removePowerObservers()
        systemSleeping = false
        if case .failed = phase {} else { phase = .idle }
        active = false
        controlActive = false
        mediaRouteLabel = "Negotiating media"
        send { $0.disconnect = ClientStep() }
    }

    /// Closes the session and stops observing it; the view is done.
    func close() {
        disconnect()
        subscription?.close()
        subscription = nil
        media?.detach(scope: scope)
    }

    private func observe() {
        guard subscription == nil, let core else { return }
        media?.attach(scope: scope, renderer: renderer) { [weak self] route in self?.mediaRouteLabel = route }
        subscription = SliceSubscription(client: core, slice: .screen, scope: scope) { [weak self] update in
            guard let self else { return }
            switch update.value {
            case .screen(let slice): self.fold(slice)
            case .failure(let failure):
                self.phase = .failed(failure.message); self.active = false; self.errorMessage = failure.message
            default: break
            }
        }
    }

    func fold(_ slice: ClientScreenSlice) {
        let next = RemoteDesktopPhase(core: slice.phase, problem: slice.problem)
        if phase != next { phase = next }
        if phaseLabel != slice.phaseLabel { phaseLabel = slice.phaseLabel }
        if active != slice.active { active = slice.active }
        if frameRates != slice.frameRates { frameRates = slice.frameRates }
        if controlUnavailableReason != slice.controlUnavailableReason {
            controlUnavailableReason = slice.controlUnavailableReason
        }
        if clipboardActionsEnabled != slice.clipboardActionsEnabled {
            clipboardActionsEnabled = slice.clipboardActionsEnabled
        }
        if latencyLabel != slice.latencyLabel { latencyLabel = slice.latencyLabel }
        let error: String? = if case .failed(let message) = next { message } else { nil }
        if errorMessage != error { errorMessage = error }
        let capabilities = slice.hasCapabilities ? slice.capabilities : .init()
        if self.capabilities != capabilities { self.capabilities = capabilities }
        let state = slice.hasState ? slice.state : .init()
        if sessionState != state { sessionState = state }
        if routeLabel != slice.routeLabel { routeLabel = slice.routeLabel }
        if !slice.active, mediaRouteLabel != "Negotiating media" { mediaRouteLabel = "Negotiating media" }
        if controlActive != slice.controlActive { controlActive = slice.controlActive }
        if canTransferControl != slice.canTransferControl { canTransferControl = slice.canTransferControl }
        if controlTransferPending != slice.controlTransferring { controlTransferPending = slice.controlTransferring }
        if controlTransferError != slice.controlError { controlTransferError = slice.controlError }
        if codecFallbackReason != slice.codecFallbackReason { codecFallbackReason = slice.codecFallbackReason }
        if clipboardEnabled != slice.clipboardEnabled { clipboardEnabled = slice.clipboardEnabled }
        if clipboardError != slice.clipboardError { clipboardError = slice.clipboardError }
        if clipboardBusy != slice.clipboardBusy { clipboardBusy = slice.clipboardBusy }
        if clipboardOperations != Int(slice.clipboardOperations) {
            clipboardOperations = Int(slice.clipboardOperations)
        }
        let preferences = slice.preferences
        if codecPreference != preferences.codec { codecPreference = preferences.codec }
        if preferences.maxFps > 0, preferredMaxFPS != preferences.maxFps { preferredMaxFPS = preferences.maxFps }
        if quality != preferences.quality { quality = preferences.quality }
        displayID = preferences.displayID
        if displayMatchingStatus != slice.displayStatus { displayMatchingStatus = slice.displayStatus }
        if !slice.cursorImageUnchanged { remoteCursor = Self.cursor(slice) }
        let cursor = RemoteDesktopCursorState(visible: slice.cursorVisible, x: slice.cursorX, y: slice.cursorY)
        if remoteCursorState != cursor { remoteCursorState = cursor }
        onCursorChange()
    }

    private static func cursor(_ slice: ClientScreenSlice) -> NSCursor {
        guard !slice.cursorImage.isEmpty, let image = NSImage(data: slice.cursorImage) else { return .arrow }
        if slice.cursorWidth > 0, slice.cursorHeight > 0 {
            image.size = NSSize(width: slice.cursorWidth, height: slice.cursorHeight)
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: slice.cursorHotspotX, y: slice.cursorHotspotY))
    }

    // MARK: Input

    func sendPointerMove(x: CGFloat, y: CGFloat) {
        onUserActivity()
        guard controlActive else { return }
        send {
            $0.pointer = .with {
                $0.x = Double(x); $0.y = Double(y)
            }
        }
    }

    func sendPointerButton(
        _ button: Dieter_V1_RemoteDesktopPointerButton.Button, down: Bool,
        clickCount: Int, x: CGFloat, y: CGFloat, modifiers: NSEvent.ModifierFlags
    ) {
        onUserActivity()
        send {
            $0.button = .with {
                $0.button = button
                $0.down = down
                $0.clicks = Int32(max(0, min(3, clickCount)))
                $0.x = Double(x)
                $0.y = Double(y)
                $0.modifiers = Self.modifiers(modifiers)
            }
        }
    }

    func sendScroll(
        deltaX: CGFloat, deltaY: CGFloat, precise: Bool, modifiers: NSEvent.ModifierFlags, phase: NSEvent.Phase = [],
        momentumPhase: NSEvent.Phase = []
    ) {
        onUserActivity()
        send {
            $0.scroll = .with {
                $0.dx = Double(deltaX)
                $0.dy = Double(deltaY)
                $0.precise = precise
                $0.phase = Int32(RemoteDesktopScrollPhases.scroll(phase))
                $0.momentum = Int32(RemoteDesktopScrollPhases.momentum(momentumPhase))
                $0.modifiers = Self.modifiers(modifiers)
            }
        }
    }

    func sendKey(code: UInt16, down: Bool, repeat isRepeat: Bool, modifiers: NSEvent.ModifierFlags) {
        onUserActivity()
        guard let physicalKey = RemoteDesktopKeyMap.macToHID[code] else { return }
        send {
            $0.key = .with {
                $0.hid = Int32(physicalKey)
                $0.down = down
                $0.repeat = isRepeat
                $0.modifiers = Self.modifiers(modifiers)
            }
        }
    }

    func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        onUserActivity()
        send { $0.text = .with { $0.text = text } }
    }

    func releaseAllInput() {
        guard controlActive else { return }
        send { $0.releaseInput = ClientStep() }
    }

    // MARK: Session

    func transferControl(take: Bool) {
        guard canTransferControl, !controlTransferPending else { return }
        controlTransferPending = true
        controlTransferError = ""
        send { $0.control = .with { $0.on = take } }
    }

    func selectCodec(_ value: Dieter_V1_RemoteDesktopCodecPreference) {
        codecPreference = value
        onUserActivity()
        sendPreferences()
    }

    func setViewport(_ size: CGSize, scale: CGFloat) {
        guard size.width > 0, size.height > 0, scale > 0 else { return }
        let points = CGSize(width: size.width, height: size.height)
        guard viewport != points else { return }
        viewport = points
        sendViewport(points, scale: scale)
    }

    func configure(
        displayID: String? = nil, quality: Dieter_V1_RemoteDesktopQuality? = nil, maxFPS: Int32? = nil,
        refresh: Bool = false
    ) {
        onUserActivity()
        if let displayID { self.displayID = displayID }
        if let quality { self.quality = quality }
        if let maxFPS {
            preferredMaxFPS = max(1, min(120, min(maxFPS, capabilities.maxFps > 0 ? capabilities.maxFps : 60)))
        }
        if displayID != nil || quality != nil || maxFPS != nil { sendPreferences() }
        if refresh { send { $0.refresh = ClientStep() } }
    }

    func setClipboardEnabled(_ on: Bool) {
        clipboardEnabled = on
        send { $0.clipboardEnabled = .with { $0.on = on } }
    }

    /// "copy", "cut", or "paste" on the host.
    func performClipboard(_ operation: String) {
        guard clipboardEnabled else { return }
        onUserActivity()
        send { $0.clipboard = .with { $0.operation = operation } }
    }

    /// Matches the host display to this screen while controlling it; nil stops.
    func setDisplayMatchingTarget(_ target: RemoteDesktopDisplayTarget?) {
        send {
            $0.matchDisplay = .with {
                if let target {
                    $0.width = Double(target.width)
                    $0.height = Double(target.height)
                    $0.scale = target.scale
                    $0.refresh = target.refresh
                }
            }
        }
    }

    func prepareForSleep() {
        systemSleeping = true
        send { $0.sleep = ClientStep() }
        onSystemSleep?()
    }

    func resumeAfterWake() {
        systemSleeping = false
        onUserActivity()
        send { $0.resume = ClientStep() }
    }

    private func sendPreferences() {
        let codec = codecPreference, fps = preferredMaxFPS, quality = quality, display = displayID
        send {
            $0.preferences = .with {
                $0.codec = codec
                $0.maxFps = fps
                $0.quality = quality
                $0.displayID = display
                $0.clipboard = true
            }
        }
    }

    private func sendViewport(_ size: CGSize, scale: CGFloat = 1) {
        send {
            $0.viewport = .with {
                $0.widthPoints = Double(size.width)
                $0.heightPoints = Double(size.height)
                $0.scale = Double(scale)
            }
        }
    }

    private func installPowerObservers() {
        removePowerObservers()
        let center = NSWorkspace.shared.notificationCenter
        wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.resumeAfterWake() }
        }
        sleepObserver = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.prepareForSleep() }
        }
    }

    private func removePowerObservers() {
        let center = NSWorkspace.shared.notificationCenter
        if let wakeObserver { center.removeObserver(wakeObserver) }
        if let sleepObserver { center.removeObserver(sleepObserver) }
        wakeObserver = nil
        sleepObserver = nil
    }

    /// Sends a screen command after those sent before, without waiting. The
    /// core has no screen for this view until it is observed.
    private func send(_ build: @escaping (inout ClientScreenCommand) -> Void) {
        guard let core, subscription != nil else { return }
        var screen = ClientScreenCommand()
        screen.scope = scope
        build(&screen)
        let command = ClientCommand.with { $0.screen = screen }
        let previous = queued
        queued = Task {
            await previous?.value
            _ = try? await core.dispatch(command)
        }
    }

    /// Waits for every command sent so far (tests and teardown).
    func settle() async {
        await queued?.value
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> Int32 {
        var value: Int32 = 0
        if flags.contains(.shift) { value |= 1 }
        if flags.contains(.control) { value |= 2 }
        if flags.contains(.option) { value |= 4 }
        if flags.contains(.command) { value |= 8 }
        if flags.contains(.capsLock) { value |= 16 }
        if flags.contains(.function) { value |= 32 }
        return value
    }
}

/// The resolution a fullscreen viewer asks the host display to match.
struct RemoteDesktopDisplayTarget: Equatable {
    var width: Int
    var height: Int
    var scale: Double
    var refresh: Double
}

// AppKit phase bitmasks differ from the Quartz event fields.
enum RemoteDesktopScrollPhases {
    static func scroll(_ phase: NSEvent.Phase) -> UInt32 {
        var value: UInt32 = 0
        if phase.contains(.began) { value |= 1 }
        if phase.contains(.changed) || phase.contains(.stationary) { value |= 2 }
        if phase.contains(.ended) { value |= 4 }
        if phase.contains(.cancelled) { value |= 8 }
        if phase.contains(.mayBegin) { value |= 128 }
        return value
    }
    static func momentum(_ phase: NSEvent.Phase) -> UInt32 {
        if phase.contains(.ended) || phase.contains(.cancelled) { return 3 }
        if phase.contains(.began) { return 1 }
        if phase.contains(.changed) || phase.contains(.stationary) { return 2 }
        return 0
    }
}
