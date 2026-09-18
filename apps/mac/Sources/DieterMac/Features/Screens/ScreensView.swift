import AppKit
import DieterAPI
import SwiftUI

struct ScreensView: View {
    @Bindable var model: ScreensModel
    let machines: [DieterEndpoint]
    let initialMachineID: String
    let makeConnection: @MainActor (String) async throws -> RemoteDesktopSignalingConnection

    var showInDieter: @MainActor () -> Void = {}

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
                    if let selectedSession {
                        if selectedSession.keepsConnectionOpen {
                            Button {
                                model.undock(selectedSession.id, showInDieter: showInDieter)
                            } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                            }
                            .help("Open screen share in full screen")
                            .accessibilityLabel("Undock screen share in full screen")
                            .accessibilityIdentifier("screens.undock")
                            .smokeTarget("screens.undock")
                        }
                        ScreenShareOptions(controller: selectedSession.controller)
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
                if selectedSession.isDetached {
                    emptyState(
                        title: selectedSession.machineName, detail: "This screen share is open in its own window.",
                        symbol: "macwindow.on.rectangle"
                    ) {
                        HStack {
                            Button("Show window") { model.undock(selectedSession.id, fullScreen: false) }
                            Button("Return to Dieter") { model.dock(selectedSession.id) }
                                .accessibilityIdentifier("screens.dock")
                        }
                    }
                } else {
                    screenWorkspace(selectedSession)
                        // The native surface owns this session's renderer and input.
                        // Reusing it would route input to a different machine's video.
                        .id(selectedSession.id)
                }
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
                Text("·")
                Text(networkLatencyLabel(controller))
                    .monospacedDigit()
                    .fixedSize()
                    .help(
                        "Network round-trip latency to the remote Mac. Does not include capture, encoding, decoding or display delay. A dash means no current measurement is available."
                    )
                    .accessibilityLabel("Network round-trip latency: \(networkLatencyLabel(controller))")
                    .accessibilityIdentifier("screens.latency")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(DieterTheme.tertiary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(DieterTheme.sidebar)
        }
        .onAppear {
            session.recordActivity()
        }

    }

    @ViewBuilder private func content(_ session: ScreenShareSession) -> some View {
        let controller = session.controller
        switch controller.phase {
        case .streaming, .connecting, .reconnecting:
            ZStack {
                Color.black
                RemoteDesktopVideoSurface(
                    session: session, toggleFullScreen: { model.undock(session.id, showInDieter: showInDieter) }
                )
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

    private func networkLatencyLabel(_ controller: RemoteDesktopController) -> String {
        let milliseconds = controller.sessionState.rttMs
        guard controller.phase == .streaming, milliseconds.isFinite, milliseconds > 0 else { return "— ms RTT" }
        if milliseconds < 1 { return "<1 ms RTT" }
        return "\(milliseconds.formatted(.number.precision(.fractionLength(0)))) ms RTT"
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
        HStack(spacing: 0) {
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
                        .overlay(Capsule().stroke(DieterTheme.border).allowsHitTesting(false))
                        .accessibilityIdentifier("screen.node.\(session.machineID)")
                        .smokeTarget("screen.badge.\(session.id)")
                }
                .frame(minWidth: 120, maxWidth: 210, alignment: .leading)
                .padding(.leading, 12)
                .padding(.trailing, 7)
                .frame(height: 38)
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
                    .frame(width: 30, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DieterTheme.tertiary)
            .help("Close screen share")
            .accessibilityLabel("Close screen share, \(session.machineName)")
            .accessibilityIdentifier("screen.close.\(session.id)")
            .smokeTarget("screen.close.\(session.id)")
        }
        .frame(height: 38)
        .background(selected ? DieterTheme.background : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(selected ? DieterTheme.shell : Color.clear).frame(height: 1).allowsHitTesting(false)
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(DieterTheme.border).frame(width: 1).allowsHitTesting(false)
        }
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
                    Text(machineLabel(machine))
                        .tag(machine.id)
                        .disabled(!machine.online || !machine.remoteDesktopReady)
                }
            }
            .accessibilityIdentifier("screens.new.machine")
            if let machine = selectedMachine, machine.online, !machine.remoteDesktopReady {
                Text(
                    machine.remoteDesktopReason.isEmpty
                        ? "This machine cannot host a screen session." : machine.remoteDesktopReason
                )
                .font(.caption)
                .foregroundStyle(DieterTheme.coral)
            }
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
                .disabled(selectedMachine?.online != true || selectedMachine?.remoteDesktopReady != true)
                .accessibilityIdentifier("screens.new.connect")
            }
        }
        .padding(20)
        .frame(width: 430)
        .onAppear {
            machineID =
                machines.first(where: {
                    $0.id == initialMachineID && $0.online && $0.remoteDesktopReady
                })?.id ?? machines.first(where: { $0.online && $0.remoteDesktopReady })?.id ?? ""
        }
    }

    private func machineLabel(_ machine: DieterEndpoint) -> String {
        if !machine.online { return "\(machine.name) — offline" }
        if !machine.remoteDesktopReady { return "\(machine.name) — unavailable" }
        return machine.name
    }
}

struct ScreenShareOptions: View {
    let controller: RemoteDesktopController
    @ViewBuilder var body: some View {
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
            Button("Enable fullscreen keyboard capture…") { RemoteDesktopKeyboardCapture.requestPermission() }
            if !controller.keyboardCaptureStatus.isEmpty { Text(controller.keyboardCaptureStatus) }
            if !controller.displayMatching.status.isEmpty { Text(controller.displayMatching.status) }
            Button("Automatic quality") { controller.configure(quality: .auto) }
            Button("Prefer sharp text") { controller.configure(quality: .detail) }
            Button("Prefer responsive motion") { controller.configure(quality: .motion) }
            Menu("Frame rate") {
                ForEach(controller.availableFrameRates, id: \.self) { rate in
                    Button("Up to \(rate) fps") { controller.configure(maxFPS: rate) }
                }
            }
            Divider()
            Toggle(
                "Compose text locally (IME)",
                isOn: Binding(
                    get: { controller.textInputMode },
                    set: { controller.textInputMode = $0 }))
            if controller.capabilities.clipboardSupported {
                Toggle(
                    "Share clipboard",
                    isOn: Binding(
                        get: { controller.clipboardEnabled },
                        set: {
                            controller.clipboardEnabled = $0; controller.clipboard.setEnabled($0)
                        })
                ).disabled(!controller.controlActive)
                Button("Copy from remote") { controller.clipboard.copySelection() }.disabled(
                    !controller.controlActive || !controller.clipboardEnabled || controller.clipboardBusy)
                Button("Paste to remote") { controller.clipboard.paste() }.disabled(
                    !controller.controlActive || !controller.clipboardEnabled || controller.clipboardBusy)
                if !controller.clipboardError.isEmpty { Text(controller.clipboardError) }
            }
            Menu("Video codec") {
                Button("Automatic (HEVC when supported)") { controller.selectCodec(.auto) }
                Button("H.264 compatibility") { controller.selectCodec(.h264) }
                Button("HEVC — up to 1080p60") { controller.selectCodec(.hevc) }
            }
            if !controller.sessionState.codec.isEmpty { Text("Codec: \(controller.sessionState.codec)") }
            if !controller.codecFallbackReason.isEmpty { Text(controller.codecFallbackReason) }
            Button("Refresh screen") { controller.configure(refresh: true) }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .accessibilityLabel("Screen options")
    }

}
