import AppKit
import DieterAPI
import SwiftUI
@preconcurrency import WebRTC

struct ScreensView: View {
    @Bindable var model: ScreensModel
    let machines: [DieterEndpoint]
    let initialMachineID: String
    let makeConnection: @MainActor (String) async throws -> RemoteDesktopSignalingConnection

    private var selectedSession: ScreenShareSession? { model.selectedSession }

    private var selectedMachine: DieterEndpoint? {
        selectedSession.flatMap { session in machines.first { $0.id == session.machineID } }
    }

    var body: some View {
        VStack(spacing: 0) {
            FluidPaneChrome {
                HStack(spacing: 12) {
                    PaneTitleBlock(
                        title: "Screens",
                        subtitle: overviewSubtitle,
                        symbol: "rectangle.inset.filled.and.person.filled",
                        prominent: true
                    )
                    Spacer()
                    if let selectedSession, selectedSession.controller.phase == .streaming {
                        screenOptions(selectedSession.controller)
                    }
                    if let selectedSession { primaryAction(selectedSession) }
                    Button {
                        model.createScreenSharePresented = true
                    } label: {
                        Label("New screen share", systemImage: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(
                        DieterTheme.shellDeep,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(machines.isEmpty)
                    .accessibilityIdentifier("screens.new")
                    .smokeTarget("screens.new")
                }
            }

            Divider().overlay(DieterTheme.border)
            if !model.sessions.isEmpty {
                screenTabs
                Divider().overlay(DieterTheme.border)
            }
            if let selectedSession {
                screenWorkspace(selectedSession)
            } else {
                emptyState(
                    title: "No open screen shares",
                    detail: "Start a machine-scoped screen share. It stays connected while you move through Dieter.",
                    symbol: "display"
                ) { EmptyView() }
            }
        }
        .background(DieterTheme.background)
        .sheet(isPresented: $model.createScreenSharePresented) {
            NewScreenShareSheet(
                model: model, machines: machines, initialMachineID: initialMachineID,
                makeConnection: makeConnection)
        }
    }

    private var screenTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(model.sessions) { session in
                    ScreenShareTab(
                        session: session,
                        selected: session.id == model.selectedSessionID,
                        select: { model.selectSession(session.id) },
                        close: { model.closeSession(session.id) })
                }
                Button {
                    model.createScreenSharePresented = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DieterTheme.tertiary)
                .help("New screen share")
            }
        }
        .frame(height: 38)
        .background(DieterTheme.sidebar)
    }

    @ViewBuilder private func screenOptions(_ controller: RemoteDesktopController) -> some View {
        if controller.canTransferControl {
            Button(controller.sessionState.controlActive ? "Release Control" : "Take Control") {
                controller.transferControl(take: !controller.sessionState.controlActive)
            }
            .disabled(controller.controlTransferPending)
            .accessibilityIdentifier("screens.control")
            .smokeTarget("screens.control")
            .help(
                controller.controlTransferError.isEmpty
                    ? "One client controls the machine at a time" : controller.controlTransferError)
        }
        Menu {
            ForEach(controller.capabilities.displays, id: \.id) { display in
                Button(display.name) { controller.configure(displayID: display.id) }
            }
            Divider()
            Button("Automatic quality") { controller.configure(quality: .auto) }
            Button("Prefer sharp text") { controller.configure(quality: .detail) }
            Button("Prefer smooth motion") { controller.configure(quality: .motion) }
            Divider()
            Toggle(
                "Compose text locally (IME)",
                isOn: Binding(
                    get: { controller.textInputMode },
                    set: { controller.textInputMode = $0 }))
            if controller.capabilities.clipboardSupported {
                Toggle("Share clipboard", isOn: Binding(get: { controller.clipboardEnabled }, set: {
                    controller.clipboardEnabled = $0; controller.clipboard.setEnabled($0)
                })).disabled(!controller.controlActive)
                Button("Copy from remote") { controller.clipboard.copySelection() }.disabled(!controller.controlActive || !controller.clipboardEnabled || controller.clipboardBusy)
                Button("Paste to remote") { controller.clipboard.paste() }.disabled(!controller.controlActive || !controller.clipboardEnabled || controller.clipboardBusy)
                if !controller.clipboardError.isEmpty { Text(controller.clipboardError) }
            }
            Button("Refresh screen") { controller.configure(refresh: true) }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .accessibilityLabel("Screen options")
    }

    @ViewBuilder private func primaryAction(_ session: ScreenShareSession) -> some View {
        let controller = session.controller
        switch controller.phase {
        case .streaming, .connecting, .reconnecting, .loading:
            Button("Disconnect") { session.disconnect() }
                .buttonStyle(DieterSecondaryButtonStyle())
                .accessibilityIdentifier("screens.disconnect")
        case .disabled:
            Button("Enable & connect") { controller.enableAndConnect() }
                .buttonStyle(DieterPrimaryButtonStyle())
                .accessibilityIdentifier("screens.enable")
        default:
            Button("Connect") {
                session.connect { [makeConnection, machineID = session.machineID] in
                    try await makeConnection(machineID)
                }
            }
            .buttonStyle(DieterPrimaryButtonStyle())
            .disabled(selectedMachine?.online != true)
            .accessibilityIdentifier("screens.connect")
        }
    }

    private func screenWorkspace(_ session: ScreenShareSession) -> some View {
        let controller = session.controller
        return VStack(spacing: 0) {
            content(session)
            Divider().overlay(DieterTheme.border)
            HStack(spacing: 8) {
                Circle().fill(statusColor(controller.phase)).frame(width: 6, height: 6)
                Text(controller.phase.label)
                if !controller.routeLabel.isEmpty {
                    Text("·")
                    Text("\(controller.routeLabel) signaling")
                }
                Spacer()
                Label(
                    controller.controlActive ? "Control active" : "View only",
                    systemImage: controller.controlActive ? "cursorarrow.motionlines" : "eye"
                )
                if controller.controlActive {
                    Text("·")
                    Text("⌘⇧Esc releases input")
                } else if !controller.controlUnavailableReason.isEmpty {
                    Text("·")
                    Text(controller.controlUnavailableReason)
                }
                Text("·")
                if controller.sessionState.connectedClients > 1 {
                    Text("\(controller.sessionState.connectedClients) viewers")
                    if !controller.sessionState.controlActive, !controller.sessionState.controllerName.isEmpty {
                        Text("\(controller.sessionState.controllerName) controls")
                    }
                }
                if !controller.controlTransferError.isEmpty {
                    Text(controller.controlTransferError).foregroundStyle(.orange)
                }
                if !controller.clipboardError.isEmpty {
                    Text("Clipboard: \(controller.clipboardError)").foregroundStyle(.orange).lineLimit(1)
                        .help(controller.clipboardError)
                }
                Text(controller.mediaRouteLabel)
                if controller.sessionState.width > 0 {
                    Text(
                        "· \(controller.sessionState.width)×\(controller.sessionState.height) · \(controller.sessionState.fps) fps"
                    )
                }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(DieterTheme.tertiary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(DieterTheme.sidebar)
        }
        .onAppear { session.recordActivity(); controller.clipboardVisible = true }
        .onDisappear { controller.clipboardVisible = false }
    }

    @ViewBuilder private func content(_ session: ScreenShareSession) -> some View {
        let controller = session.controller
        switch controller.phase {
        case .streaming, .connecting, .reconnecting:
            ZStack {
                Color.black
                RemoteDesktopVideoSurface(controller: controller)
                    .padding(18)
                if controller.phase != .streaming {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(controller.phase.label).font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    .background(
                        .black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .foregroundStyle(.white)
                }
            }
            .accessibilityIdentifier("screens.video")
        case .loading:
            emptyState(
                title: "Checking \(session.machineName)",
                detail: "Dieter is checking capture permission and negotiating an authenticated route.",
                symbol: "ellipsis"
            ) { ProgressView().controlSize(.small) }
        case .disabled(let reason):
            emptyState(
                title: "Screen sharing is off",
                detail: reason.isEmpty ? "Enable remote desktop on this machine to continue." : reason,
                symbol: "rectangle.slash"
            ) { EmptyView() }
        case .failed(let message):
            emptyState(
                title: "Couldn’t connect", detail: message,
                symbol: "exclamationmark.triangle"
            ) { EmptyView() }
        case .idle:
            emptyState(
                title: session.machineName,
                detail: session.inactivityMessage ?? idleDetail(session),
                symbol: selectedMachine?.online == false ? "wifi.slash" : "display"
            ) { EmptyView() }
        }
    }

    private func idleDetail(_ session: ScreenShareSession) -> String {
        guard let machine = machines.first(where: { $0.id == session.machineID }) else {
            return "This machine is no longer enrolled."
        }
        if !machine.online { return MachinePresenceText.lastSeen(machine.lastSeenAt) }
        return machine.remoteDesktopReason.isEmpty
            ? "Connect for an authenticated remote session with \(machine.name)."
            : machine.remoteDesktopReason
    }

    private var overviewSubtitle: String {
        let count = model.sessions.count
        let machineCount = Set(model.sessions.map(\.machineID)).count
        guard count > 0 else { return "Machine-scoped remote desktop sessions" }
        return
            "\(count) open \(count == 1 ? "share" : "shares") across \(machineCount) \(machineCount == 1 ? "machine" : "machines")"
    }

    private func statusColor(_ phase: RemoteDesktopPhase) -> Color {
        switch phase {
        case .streaming: DieterTheme.eyes
        case .loading, .connecting, .reconnecting: DieterTheme.amber
        case .failed: DieterTheme.coral
        default: DieterTheme.tertiary
        }
    }

    private func emptyState<Accessory: View>(
        title: String, detail: String, symbol: String, @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        VStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(DieterTheme.selection)
                    .frame(width: 62, height: 62)
                Image(systemName: symbol)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(DieterTheme.shell)
            }
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(DieterTheme.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            accessory()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ScreenShareTab: View {
    let session: ScreenShareSession
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Button(action: select) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(session.isConnected ? DieterTheme.eyes : DieterTheme.tertiary)
                        .frame(width: 5, height: 5)
                    Text("Screen")
                        .font(.system(size: 11, weight: selected ? .semibold : .medium))
                    Text(session.machineName)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(DieterTheme.subtle)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(DieterTheme.raised, in: Capsule())
                        .overlay(Capsule().stroke(DieterTheme.border))
                        .accessibilityIdentifier("screen.node.\(session.machineID)")
                }
                .frame(minWidth: 120, maxWidth: 210, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Screen, \(session.machineName)")
            .accessibilityIdentifier("screen.select.\(session.id)")
            .smokeTarget("screen.select.\(session.id)")

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .background(hovering ? DieterTheme.raised : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DieterTheme.tertiary)
            .help("Close screen share")
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .frame(height: 38)
        .background(selected ? DieterTheme.background : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(selected ? DieterTheme.shell : Color.clear).frame(height: 1)
        }
        .overlay(alignment: .trailing) { Rectangle().fill(DieterTheme.border).frame(width: 1) }
        .onHover { hovering = $0 }
        .contextMenu { Button("Close screen share", action: close) }
    }
}

private struct NewScreenShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ScreensModel
    let machines: [DieterEndpoint]
    let initialMachineID: String
    let makeConnection: @MainActor (String) async throws -> RemoteDesktopSignalingConnection
    @State private var machineID = ""

    private var selectedMachine: DieterEndpoint? { machines.first { $0.id == machineID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New screen share").font(.system(size: 17, weight: .semibold))
                Text("Screen shares belong to a machine and stay connected while you use other parts of Dieter.")
                    .font(.caption).foregroundStyle(DieterTheme.tertiary)
            }
            Picker("Machine", selection: $machineID) {
                ForEach(machines) { machine in
                    Text(machine.online ? machine.name : "\(machine.name) — offline").tag(machine.id)
                }
            }
            .accessibilityIdentifier("screens.new.machine")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connect") {
                    guard let machine = selectedMachine else { return }
                    model.createSession(machineID: machine.id, machineName: machine.name) {
                        [makeConnection, machineID = machine.id] in
                        try await makeConnection(machineID)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedMachine?.online != true)
                .accessibilityIdentifier("screens.new.connect")
            }
        }
        .padding(20)
        .frame(width: 430)
        .onAppear {
            machineID =
                machines.contains(where: { $0.id == initialMachineID })
                ? initialMachineID : (machines.first?.id ?? "")
        }
    }
}

private struct RemoteDesktopVideoSurface: NSViewRepresentable {
    let controller: RemoteDesktopController

    func makeNSView(context: Context) -> RemoteDesktopInputView {
        RemoteDesktopInputView(renderer: controller.renderer, controller: controller)
    }
    func updateNSView(_ nsView: RemoteDesktopInputView, context: Context) {
        nsView.controller = controller
        nsView.refreshCursor()
    }
}

@MainActor
final class RemoteDesktopInputView: NSView, @preconcurrency NSTextInputClient, @preconcurrency RTCVideoViewDelegate {
    let renderer: RemoteDesktopMetalView
    weak var controller: RemoteDesktopController?
    private var videoSize = CGSize(width: 16, height: 9)
    private var trackingAreaReference: NSTrackingArea?
    private var buttonsDown = Set<Int>()
    private var modifierKeysDown = Set<UInt16>()
    private var physicalKeysDown = Set<UInt16>()
    private var markedText = NSAttributedString(string: "")
    private var markedSelection = NSRange(location: NSNotFound, length: 0)
    private let focusObserverBag = RemoteDesktopFocusObservers()
    private let hostCursorView = NSImageView()

    init(renderer: RemoteDesktopMetalView, controller: RemoteDesktopController) {
        self.renderer = renderer
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        renderer.delegate = self
        addSubview(renderer)
        hostCursorView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(hostCursorView)
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        controller?.clipboardWindow = window
        focusObserverBag.tokens.forEach(NotificationCenter.default.removeObserver)
        focusObserverBag.tokens.removeAll()
        for (name, object) in [
            (NSApplication.didResignActiveNotification, NSApp as AnyObject?),
            (NSWindow.didResignKeyNotification, window as AnyObject?),
        ] {
            focusObserverBag.tokens.append(
                NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.releaseFocus() }
                })
        }
        if window == nil { releaseFocus() }
    }
    override func becomeFirstResponder() -> Bool {
        controller?.inputFocused = true
        return super.becomeFirstResponder()
    }
    private func releaseFocus() {
        controller?.inputFocused = false
        controller?.releaseAllInput()
        buttonsDown.removeAll(); modifierKeysDown.removeAll(); physicalKeysDown.removeAll()
        unmarkText()
    }
    func refreshCursor() {
        guard let controller else { return }
        window?.invalidateCursorRects(for: self)
        let state = controller.remoteCursorState
        hostCursorView.isHidden =
            controller.sessionState.embeddedCursor || !state.visible
            || (controller.controlActive && controller.inputFocused)
        guard !hostCursorView.isHidden else { return }
        let rect = RemoteDesktopInputGeometry.contentRect(bounds: bounds, videoSize: videoSize)
        let cursor = controller.remoteCursor
        hostCursorView.image = cursor.image
        hostCursorView.frame = NSRect(
            x: rect.minX + rect.width * Double(state.normalizedX) / 1_000_000 - cursor.hotSpot.x,
            y: rect.maxY - rect.height * Double(state.normalizedY) / 1_000_000 - cursor.image.size.height
                + cursor.hotSpot.y,
            width: cursor.image.size.width, height: cursor.image.size.height)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if let controller, controller.controlActive, !controller.sessionState.embeddedCursor {
            addCursorRect(
                RemoteDesktopInputGeometry.contentRect(bounds: bounds, videoSize: videoSize),
                cursor: controller.remoteCursor)
        }
    }
    override func layout() {
        super.layout()
        renderer.frame = bounds
        controller?.setViewport(bounds.size, scale: window?.backingScaleFactor ?? 1)
        refreshCursor()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        controller?.setViewport(bounds.size, scale: window?.backingScaleFactor ?? 1)
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    func videoView(_ videoView: any RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        videoSize = size.width > 0 && size.height > 0 ? size : videoSize
    }

    override func mouseMoved(with event: NSEvent) { sendMove(event) }
    override func mouseDragged(with event: NSEvent) { sendMove(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMove(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMove(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendButton(.left, down: true, event: event)
    }
    override func mouseUp(with event: NSEvent) { sendButton(.left, down: false, event: event) }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendButton(.right, down: true, event: event)
    }
    override func rightMouseUp(with event: NSEvent) { sendButton(.right, down: false, event: event) }
    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendButton(button(event.buttonNumber), down: true, event: event)
    }
    override func otherMouseUp(with event: NSEvent) {
        sendButton(button(event.buttonNumber), down: false, event: event)
    }

    override func scrollWheel(with event: NSEvent) {
        controller?.sendScroll(
            deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas, modifiers: event.modifierFlags, phase: event.phase,
            momentumPhase: event.momentumPhase)
    }

    override func keyDown(with event: NSEvent) {
        if [7, 8, 9].contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
            controller?.capabilities.clipboardSupported == true, controller?.clipboardEnabled == true {
            if !event.isARepeat {
                switch event.keyCode {
                case 7: controller?.clipboard.cut()
                case 8: controller?.clipboard.copySelection()
                default: controller?.clipboard.paste()
                }
            }
            return
        }
        if event.keyCode == 53 && event.modifierFlags.contains([.command, .shift]) {
            controller?.releaseAllInput()
            window?.makeFirstResponder(nil)
            return
        }
        if controller?.textInputMode == true, !event.modifierFlags.contains(.command),
            !event.modifierFlags.contains(.control)
        {
            interpretKeyEvents([event])
            return
        }
        physicalKeysDown.insert(event.keyCode)
        controller?.sendKey(
            code: event.keyCode, down: true, repeat: event.isARepeat,
            modifiers: event.modifierFlags)
    }
    override func keyUp(with event: NSEvent) {
        guard physicalKeysDown.remove(event.keyCode) != nil else { return }
        controller?.sendKey(
            code: event.keyCode, down: false, repeat: false, modifiers: event.modifierFlags)
    }
    override func flagsChanged(with event: NSEvent) {
        let down: Bool
        if event.keyCode == 57 {
            down = event.modifierFlags.contains(.capsLock)
        } else {
            down =
                !modifierKeysDown.contains(event.keyCode)
                && modifierIsDown(keyCode: event.keyCode, flags: event.modifierFlags)
        }
        if down { modifierKeysDown.insert(event.keyCode) } else { modifierKeysDown.remove(event.keyCode) }
        controller?.sendKey(
            code: event.keyCode, down: down, repeat: false, modifiers: event.modifierFlags)
    }
    override func resignFirstResponder() -> Bool {
        releaseFocus()
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, controller?.controlActive == true else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    private func sendMove(_ event: NSEvent) {
        guard let point = normalizedPoint(event, clamp: !buttonsDown.isEmpty) else { return }
        if controller?.sessionState.embeddedCursor == false { controller?.remoteCursor.set() }
        controller?.sendPointerMove(x: point.x, y: point.y)
    }

    private func sendButton(
        _ button: Dieter_V1_RemoteDesktopPointerButton.Button, down: Bool, event: NSEvent
    ) {
        guard down || buttonsDown.contains(event.buttonNumber), let point = normalizedPoint(event, clamp: !down) else {
            return
        }
        if down { buttonsDown.insert(event.buttonNumber) } else { buttonsDown.remove(event.buttonNumber) }
        controller?.sendPointerButton(
            button, down: down, clickCount: event.clickCount, x: point.x, y: point.y,
            modifiers: event.modifierFlags)
    }

    private func normalizedPoint(_ event: NSEvent, clamp: Bool = false) -> CGPoint? {
        let point = convert(event.locationInWindow, from: nil)
        return RemoteDesktopInputGeometry.normalized(point: point, bounds: bounds, videoSize: videoSize, clamp: clamp)
    }

    private func button(_ number: Int) -> Dieter_V1_RemoteDesktopPointerButton.Button {
        switch number {
        case 2: .middle
        case 3: .back
        case 4: .forward
        default: .middle
        }
    }

    private func modifierIsDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        switch keyCode {
        case 54, 55: flags.contains(.command)
        case 56, 60: flags.contains(.shift)
        case 57: flags.contains(.capsLock)
        case 58, 61: flags.contains(.option)
        case 59, 62: flags.contains(.control)
        case 63: flags.contains(.function)
        default: false
        }
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        controller?.sendText(text); unmarkText()
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
        markedSelection = selectedRange
    }
    func unmarkText() {
        markedText = NSAttributedString(string: ""); markedSelection = NSRange(location: NSNotFound, length: 0)
    }
    func selectedRange() -> NSRange { markedSelection }
    func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }
    func hasMarkedText() -> Bool { markedText.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.location != NSNotFound, NSMaxRange(range) <= markedText.length else { return nil }
        actualRange?.pointee = range; return markedText.attributedSubstring(from: range)
    }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = markedRange()
        return window?.convertToScreen(convert(NSRect(x: bounds.midX, y: bounds.midY, width: 1, height: 20), to: nil))
            ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    override func doCommand(by selector: Selector) {
        // Commands produced by the local input method (arrows, delete, return).
        let keys: [String: UInt16] = [
            "insertNewline:": 36, "insertTab:": 48, "deleteBackward:": 51, "deleteForward:": 117,
            "moveLeft:": 123, "moveRight:": 124, "moveDown:": 125, "moveUp:": 126, "cancelOperation:": 53,
        ]
        if let code = keys[NSStringFromSelector(selector)] {
            controller?.sendKey(code: code, down: true, repeat: false, modifiers: [])
            controller?.sendKey(code: code, down: false, repeat: false, modifiers: [])
        }
    }

}

enum RemoteDesktopInputGeometry {
    static func normalized(point: CGPoint, bounds: CGRect, videoSize: CGSize, clamp: Bool = false) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0, videoSize.width > 0, videoSize.height > 0 else {
            return nil
        }
        let content = contentRect(bounds: bounds, videoSize: videoSize)
        guard clamp || content.contains(point) else { return nil }
        return CGPoint(
            x: max(0, min(1, (point.x - content.minX) / content.width)),
            y: max(0, min(1, 1 - (point.y - content.minY) / content.height)))
    }
    static func contentRect(bounds: CGRect, videoSize: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return .zero }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
}

private final class RemoteDesktopFocusObservers {
    var tokens: [NSObjectProtocol] = []
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}
