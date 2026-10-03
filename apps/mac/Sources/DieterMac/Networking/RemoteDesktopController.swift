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

/// One screen view over the shared core's screen session (`session`), which
/// owns the slice, the command queue, and every word the view shows. This
/// adapter maps AppKit input to screen commands, turns the host cursor into an
/// `NSCursor`, and follows system sleep. Video renders natively:
/// `CoreScreenMedia` decodes into `renderer`.
@MainActor
@Observable
final class RemoteDesktopController {
    let session: ScreenSessionModel
    var machineName = ""
    private(set) var remoteCursor: NSCursor = .arrow
    /// The input view holds keyboard focus in an active window; the core only
    /// sends input, and syncs the clipboard, while it does.
    var inputFocused = false {
        didSet {
            guard inputFocused != oldValue else { return }
            session.setFocused(inputFocused)
        }
    }
    var textInputMode = false
    /// What the session asks for at the next connect, until the core reports its own.
    var preferredMaxFPS: Int32 = 60
    var codecPreference: Dieter_V1_RemoteDesktopCodecPreference = .h264
    var keyboardCaptureStatus = ""
    @ObservationIgnored var onCursorChange: @MainActor () -> Void = {}
    @ObservationIgnored var onUserActivity: @MainActor () -> Void = {}
    @ObservationIgnored var onSystemSleep: (() -> Void)?
    private(set) var systemSleeping = false

    let renderer: RemoteDesktopMetalView
    @ObservationIgnored private var cursorImage = Data()
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var sleepObserver: NSObjectProtocol?

    init(core: CoreClient? = nil, media: CoreScreenMedia? = nil) {
        let renderer = RemoteDesktopMetalView(frame: .zero)
        self.renderer = renderer
        session = ScreenSessionModel(core: core, media: media, renderer: renderer, scopePrefix: "screen")
        session.onFold = { [weak self] _ in self?.folded() }
    }

    var scope: String { session.scope }
    var phase: RemoteDesktopPhase { RemoteDesktopPhase(core: session.phase, problem: session.problem) }
    var phaseLabel: String { session.phaseLabel }
    var active: Bool { session.active }
    var capabilities: Dieter_V1_RemoteDesktopCapabilities { session.capabilities }
    var sessionState: Dieter_V1_RemoteDesktopSessionState { session.sessionState }
    var routeLabel: String { session.routeLabel }
    /// Why the session failed, while it has.
    var errorMessage: String? { session.failed ? session.problem : nil }
    var remoteCursorState: RemoteDesktopCursorState {
        RemoteDesktopCursorState(visible: session.cursor.visible, x: session.cursor.x, y: session.cursor.y)
    }
    var controlActive: Bool { session.controlActive }
    var canTransferControl: Bool { session.canTransferControl }
    var controlTransferPending: Bool { session.controlTransferring }
    var controlTransferError: String { session.controlError }
    var controlUnavailableReason: String { session.controlUnavailableReason }
    var codecFallbackReason: String { session.codecFallbackReason }
    var clipboardEnabled: Bool { session.clipboardEnabled }
    var clipboardError: String { session.clipboardError }
    var clipboardBusy: Bool { session.clipboardBusy }
    var clipboardOperations: Int { session.clipboardOperations }
    var clipboardActionsEnabled: Bool { session.clipboardActionsEnabled }
    var latencyLabel: String { session.latencyLabel }
    var frameRates: [Int32] { session.frameRates }
    var quality: Dieter_V1_RemoteDesktopQuality { session.preferences.quality }
    var displayMatchingStatus: String { session.displayStatus }
    var currentDisplayID: String { session.preferences.displayID }

    /// Opens a session with `daemonID`; an earlier one closes first.
    func connect(daemonID: String, machineName: String) {
        self.machineName = machineName
        installPowerObservers()
        var preferences = session.preferences
        preferences.codec = codecPreference
        preferences.maxFps = preferredMaxFPS
        preferences.clipboard = true
        session.connect(daemonID: daemonID, preferences: preferences)
    }

    func disconnect() {
        removePowerObservers()
        systemSleeping = false
        session.disconnect()
    }

    /// Closes the session and stops observing it; the view is done.
    func close() {
        removePowerObservers()
        session.close()
    }

    private func folded() {
        let preferences = session.preferences
        if codecPreference != preferences.codec { codecPreference = preferences.codec }
        if preferences.maxFps > 0, preferredMaxFPS != preferences.maxFps { preferredMaxFPS = preferences.maxFps }
        if cursorImage != session.cursorImage {
            cursorImage = session.cursorImage
            remoteCursor = Self.cursor(image: cursorImage, state: session.cursor)
        }
        onCursorChange()
    }

    private static func cursor(image data: Data, state: ScreenCursorState) -> NSCursor {
        guard !data.isEmpty, let image = NSImage(data: data) else { return .arrow }
        if state.width > 0, state.height > 0 { image.size = NSSize(width: state.width, height: state.height) }
        return NSCursor(image: image, hotSpot: NSPoint(x: state.hotspotX, y: state.hotspotY))
    }

    // MARK: Input

    func sendPointerMove(x: CGFloat, y: CGFloat) {
        onUserActivity()
        guard controlActive else { return }
        session.send {
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
        session.send {
            $0.button = .with {
                $0.button = button
                $0.down = down
                $0.clicks = Int32(clamping: clickCount)
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
        session.send {
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
        session.send {
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
        session.send { $0.text = .with { $0.text = text } }
    }

    func releaseAllInput() {
        guard controlActive else { return }
        session.releaseInput()
    }

    // MARK: Session

    func transferControl(take: Bool) { session.transferControl(take: take) }

    func selectCodec(_ value: Dieter_V1_RemoteDesktopCodecPreference) {
        codecPreference = value
        onUserActivity()
        session.setPreferences { $0.codec = value }
    }

    func setViewport(_ size: CGSize, scale: CGFloat) { session.setViewport(size, scale: scale) }

    /// Changes the display, quality, or frame rate (one of `frameRates`), or asks for a fresh frame.
    func configure(
        displayID: String? = nil, quality: Dieter_V1_RemoteDesktopQuality? = nil, maxFPS: Int32? = nil,
        refresh: Bool = false
    ) {
        onUserActivity()
        if let maxFPS { preferredMaxFPS = maxFPS }
        if displayID != nil || quality != nil || maxFPS != nil {
            session.setPreferences {
                if let displayID { $0.displayID = displayID }
                if let quality { $0.quality = quality }
                if let maxFPS { $0.maxFps = maxFPS }
            }
        }
        if refresh { session.refresh() }
    }

    func setClipboardEnabled(_ on: Bool) { session.setClipboardEnabled(on) }

    /// "copy", "cut", or "paste" on the host.
    func performClipboard(_ operation: String) {
        guard clipboardEnabled else { return }
        onUserActivity()
        session.performClipboard(operation)
    }

    /// Matches the host display to this screen while controlling it; nil stops.
    func setDisplayMatchingTarget(_ target: RemoteDesktopDisplayTarget?) {
        guard let target else { return session.stopMatchingDisplay() }
        session.matchDisplay(
            width: Double(target.width), height: Double(target.height), scale: target.scale, refresh: target.refresh)
    }

    func prepareForSleep() {
        systemSleeping = true
        session.setAsleep(true)
        onSystemSleep?()
    }

    func resumeAfterWake() {
        systemSleeping = false
        onUserActivity()
        session.setAsleep(false)
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

    /// Waits for every command sent so far (tests and teardown).
    func settle() async {
        await session.settle()
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

#if DEBUG
    extension RemoteDesktopController {
        /// Folds `change` into the session's last slice, as the core would
        /// report it; fixtures and tests have no peer to change it.
        func showFixture(_ change: (inout ClientScreenSlice) -> Void) {
            var slice = session.lastSlice
            change(&slice)
            session.fold(slice)
        }
    }
#endif
