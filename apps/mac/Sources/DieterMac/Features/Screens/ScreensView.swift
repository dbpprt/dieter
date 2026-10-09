import AppKit
import DieterAPI
import DieterShared
import SwiftUI

struct ScreensView: View {
    @Bindable var model: ScreensModel
    let machines: [MachineEndpoint]
    let initialMachineID: String
    /// Each machine as the core presents it, by machine ID.
    var entries: [String: ClientMachineEntry] = [:]

    var showInDieter: @MainActor () -> Void = {}

    private var selectedSession: ScreenShareSession? { model.selectedSession }

    private var selectedMachine: MachineEndpoint? {
        selectedSession.flatMap { session in machines.first { $0.id == session.machineID } }
    }

    var body: some View {
        DieterSectionScaffold {
            DieterTitleCapsule(
                title: "Screens", count: model.sessions.isEmpty ? nil : model.sessions.count, detail: overviewSubtitle)
        } trailing: {
            if let selectedSession {
                if selectedSession.keepsConnectionOpen {
                    Button {
                        model.undock(selectedSession.id, showInDieter: showInDieter)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(DieterBarButtonStyle(shape: .circle))
                    .help("Open screen share in full screen")
                    .accessibilityLabel("Undock screen share in full screen")
                    .accessibilityIdentifier("screens.undock")
                    .smokeTarget("screens.undock")
                }
                ScreenShareOptions(controller: selectedSession.controller)
                primaryAction(selectedSession)
            }
            Button {
                model.createScreenSharePresented = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    Text("New screen share")
                }
            }
            .buttonStyle(DieterBarButtonStyle())
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(machines.isEmpty)
            .accessibilityIdentifier("screens.new")
            .smokeTarget("screens.new")
        } content: {
            VStack(spacing: 0) {
                if !model.sessions.isEmpty {
                    screenTabs
                    Rectangle().fill(DieterTheme.hairline).frame(height: 1)
                }
                if let selectedSession {
                    if selectedSession.isDetached {
                        emptyState(
                            title: selectedSession.machineName, detail: "This screen share is open in its own window.",
                            symbol: "macwindow.on.rectangle"
                        ) {
                            HStack(spacing: 8) {
                                Button("Show window") { model.undock(selectedSession.id, fullScreen: false) }
                                    .buttonStyle(DieterBarButtonStyle())
                                Button("Return to Dieter") { model.dock(selectedSession.id) }
                                    .buttonStyle(DieterBarButtonStyle(prominent: true))
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
                        detail:
                            "Start a machine-scoped screen share. It stays connected while you move through Dieter.",
                        symbol: "display"
                    ) { EmptyView() }
                }
            }
        }
        .sheet(isPresented: $model.createScreenSharePresented) {
            NewScreenShareSheet(
                model: model, machines: machines, initialMachineID: initialMachineID, entries: entries)
        }
    }

    private var screenTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                DieterSegmentTrack {
                    ForEach(model.sessions) { session in
                        ScreenShareTab(
                            session: session,
                            selected: session.id == model.selectedSessionID,
                            select: { model.selectSession(session.id) },
                            close: { model.closeSession(session.id) })
                    }
                }
                Button {
                    model.createScreenSharePresented = true
                } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 26))
                .help("New screen share")
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 44)
    }

    @ViewBuilder private func primaryAction(_ session: ScreenShareSession) -> some View {
        if session.controller.active {
            Button("Disconnect") { session.disconnect() }
                .buttonStyle(DieterBarButtonStyle())
                .accessibilityIdentifier("screens.disconnect")
        } else {
            Button("Connect") { session.connect() }
                .buttonStyle(DieterBarButtonStyle(prominent: true))
                .disabled(selectedMachine.flatMap { entries[$0.id] }?.canShareScreen != true)
                .accessibilityIdentifier("screens.connect")
        }
    }

    private func screenWorkspace(_ session: ScreenShareSession) -> some View {
        let controller = session.controller
        return VStack(spacing: 0) {
            content(session)
            Divider().overlay(DieterTheme.border)
            HStack(spacing: 8) {
                Circle().fill(controller.session.tone.color).frame(width: 6, height: 6)
                Text(controller.phaseLabel)
                if !controller.routeLabel.isEmpty {
                    Text("·")
                    Text("\(controller.routeLabel) signaling")
                }
                Spacer()
                Label(
                    controller.session.controlLabel,
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
                if !controller.session.viewersLabel.isEmpty {
                    Text(controller.session.viewersLabel)
                }
                if !controller.controlTransferError.isEmpty {
                    Text(controller.controlTransferError).foregroundStyle(.orange)
                }
                if !controller.clipboardError.isEmpty {
                    Text("Clipboard: \(controller.clipboardError)").foregroundStyle(.orange).lineLimit(1)
                        .help(controller.clipboardError)
                }
                if controller.session.streaming {
                    Text(controller.session.metadata)
                }
                Text("·")
                Text(controller.latencyLabel)
                    .monospacedDigit()
                    .fixedSize()
                    .help(
                        "Network round-trip latency to the remote Mac. Does not include capture, encoding, decoding or display delay. A dash means no current measurement is available."
                    )
                    .accessibilityLabel("Network round-trip latency: \(controller.latencyLabel)")
                    .accessibilityIdentifier("screens.latency")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(DieterTheme.tertiary)
            .padding(.horizontal, 12)
            .frame(height: 28)
        }
        .onAppear {
            session.recordActivity()
        }

    }

    @ViewBuilder private func content(_ session: ScreenShareSession) -> some View {
        let controller = session.controller
        switch controller.phase {
        case .streaming, .connecting, .waitingForHostApproval, .reconnecting:
            ZStack {
                Color.black
                RemoteDesktopVideoSurface(
                    session: session, toggleFullScreen: { model.undock(session.id, showInDieter: showInDieter) }
                )
                .padding(18)
                if controller.phase != .streaming {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(controller.phaseLabel).font(.system(size: 12, weight: .semibold))
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
        case .permissionRequired, .unsupported:
            emptyState(
                title: session.controller.phaseLabel,
                detail: controller.phase.waitingMessage(hostReady: false, hostReason: hostReason(session)),
                symbol: "lock.shield"
            ) {
                if case .permissionRequired = session.controller.phase {
                    VStack(spacing: 8) {
                        Text("On \(session.machineName), run:")
                        Text("dieter daemon permissions").font(.system(.body, design: .monospaced)).textSelection(
                            .enabled)
                        Text("Follow the permission guide on that machine, then connect again.")
                    }
                }
            }
        case .failed:
            emptyState(
                title: "Couldn’t connect",
                detail: controller.phase.waitingMessage(hostReady: true, hostReason: ""),
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

    /// Why the session's machine cannot share its screen, when it says.
    private func hostReason(_ session: ScreenShareSession) -> String {
        machines.first(where: { $0.id == session.machineID })?.remoteDesktopReason ?? ""
    }

    /// What an idle session says, as the core words it for the machine's readiness to share.
    private func idleDetail(_ session: ScreenShareSession) -> String {
        let entry = entries[session.machineID]
        if let entry, !entry.unavailableMessage.isEmpty { return entry.unavailableMessage }
        return session.controller.phase.waitingMessage(
            hostReady: entry?.remoteDesktopReady ?? false, hostReason: entry?.remoteDesktopReason ?? "")
    }

    private var overviewSubtitle: String {
        let count = model.sessions.count
        guard count > 0 else { return "Machine-scoped remote desktop sessions" }
        let machines = Set(model.sessions.map(\.machineID)).count
        return
            "\(SharedRules.shared.count(count: Int32(count), noun: "open share", plural: "")) across \(SharedRules.shared.count(count: Int32(machines), noun: "machine", plural: ""))"
    }

    private func emptyState<Accessory: View>(
        title: String, detail: String, symbol: String, @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        VStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(DieterTheme.tileHover)
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
    @State private var closeHovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 7) {
                Circle()
                    .fill(session.isConnected ? DieterTheme.running : DieterTheme.tertiary)
                    .frame(width: 6, height: 6)
                Text("Screen")
                Text(session.machineName)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(DieterTheme.subtle)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(DieterTheme.tileHover, in: Capsule())
                    .accessibilityIdentifier("screen.node.\(session.machineID)")
                    .smokeTarget("screen.badge.\(session.id)")
            }
            .frame(minWidth: 120, maxWidth: 210, alignment: .leading)
            // Room for the close button, which sits inside the segment's trailing edge.
            .padding(.trailing, 14)
        }
        .buttonStyle(DieterSegmentStyle(selected: selected))
        .accessibilityLabel("Screen, \(session.machineName)")
        .accessibilityIdentifier("screen.select.\(session.id)")
        .smokeTarget("screen.select.\(session.id)")
        .overlay(alignment: .trailing) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .background(closeHovering ? DieterTheme.text.opacity(0.1) : Color.clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DieterTheme.tertiary)
            .onHover { closeHovering = $0 }
            .help("Close screen share")
            .accessibilityLabel("Close screen share, \(session.machineName)")
            .accessibilityIdentifier("screen.close.\(session.id)")
            .smokeTarget("screen.close.\(session.id)")
            .padding(.trailing, 7)
        }
        .contextMenu { Button("Close screen share", action: close) }
    }
}

private struct NewScreenShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ScreensModel
    let machines: [MachineEndpoint]
    let initialMachineID: String
    let entries: [String: ClientMachineEntry]
    @State private var machineID = ""

    private var selectedMachine: MachineEndpoint? { machines.first { $0.id == machineID } }

    private func canShare(_ machine: MachineEndpoint) -> Bool { entries[machine.id]?.canShareScreen == true }

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
                        .disabled(!canShare(machine))
                }
            }
            .accessibilityIdentifier("screens.new.machine")
            if let machine = selectedMachine, canShare(machine), !machine.remoteDesktopReady {
                Text(
                    machine.remoteDesktopReason.isEmpty
                        ? entries[machine.id]?.screenStatus ?? "" : machine.remoteDesktopReason
                )
                .font(.caption)
                .foregroundStyle(DieterTheme.coral)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(DieterBarButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    guard let machine = selectedMachine else { return }
                    model.createSession(
                        machineID: machine.id, daemonID: machine.daemonID ?? "", machineName: machine.name)
                    dismiss()
                }
                .buttonStyle(DieterBarButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(selectedMachine.map(canShare) != true)
                .accessibilityIdentifier("screens.new.connect")
            }
        }
        .padding(20)
        .frame(width: 430)
        .onAppear {
            machineID =
                machines.first(where: {
                    $0.id == initialMachineID && canShare($0)
                })?.id ?? machines.first(where: { canShare($0) && $0.remoteDesktopReady })?.id
                ?? machines.first(where: { canShare($0) })?.id ?? ""
        }
    }

    private func machineLabel(_ machine: MachineEndpoint) -> String {
        guard let entry = entries[machine.id], !(entry.canShareScreen && machine.remoteDesktopReady) else {
            return machine.name
        }
        return "\(machine.name) — \(entry.screenStatus)"
    }
}

struct ScreenShareOptions: View {
    let controller: RemoteDesktopController
    var size: CGFloat = DieterMetrics.capsuleHeight

    /// The core's quality and codec choices, in menu order.
    private static let options: ClientScreenStreamOptions =
        (try? ClientScreenStreamOptions(serializedBytes: SharedRules.shared.screenStreamOptions())) ?? .init()

    @ViewBuilder var body: some View {
        if controller.canTransferControl {
            Button(SharedRules.shared.screenControlAction(controlActive: controller.sessionState.controlActive)) {
                controller.transferControl(take: !controller.sessionState.controlActive)
            }
            .buttonStyle(DieterBarButtonStyle(size: size))
            .disabled(controller.controlTransferPending)
            .accessibilityIdentifier("screens.control")
            .smokeTarget("screens.control")
            .help(
                controller.controlTransferError.isEmpty
                    ? "One client controls the machine at a time" : controller.controlTransferError)
        }
        Menu {
            if controller.capabilities.virtualDisplaySupported {
                Toggle(
                    "Virtual display (experimental)",
                    isOn: Binding(
                        get: { controller.session.preferences.virtualDisplay },
                        set: { enabled in
                            controller.session.setPreferences {
                                $0.virtualDisplay = enabled; $0.disablePhysical = false
                            }
                        }
                    )
                ).disabled(!controller.controlActive)
                Toggle(
                    "Turn off host screen",
                    isOn: Binding(
                        get: { controller.session.preferences.disablePhysical },
                        set: { enabled in controller.session.setPreferences { $0.disablePhysical = enabled } }
                    )
                ).disabled(
                    !controller.session.preferences.virtualDisplay
                        || !controller.capabilities.virtualDisplayDisableSupported || !controller.controlActive)
                Toggle(
                    "Larger desktop text (2×)",
                    isOn: Binding(
                        get: { controller.session.preferences.virtualScale != 1 },
                        set: { enabled in controller.session.setPreferences { $0.virtualScale = enabled ? 2 : 1 } }
                    )
                ).disabled(!controller.session.preferences.virtualDisplay)
                Divider()
            }
            ForEach(controller.capabilities.displays, id: \.id) { display in
                Button(display.name) { controller.configure(displayID: display.id) }.disabled(
                    controller.session.preferences.virtualDisplay)
            }
            Divider()
            if !controller.keyboardCaptureStatus.isEmpty { Text(controller.keyboardCaptureStatus) }
            if !controller.displayMatchingStatus.isEmpty { Text(controller.displayMatchingStatus) }
            ForEach(Self.options.qualities, id: \.quality) { choice in
                Button(choice.label) { controller.configure(quality: choice.quality) }
            }
            Menu("Frame rate") {
                ForEach(controller.frameRates, id: \.self) { rate in
                    Button(SharedRules.shared.screenFrameRate(fps: rate)) { controller.configure(maxFPS: rate) }
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
                        set: { controller.setClipboardEnabled($0) })
                ).disabled(!controller.controlActive)
                Button("Copy from remote") { controller.performClipboard("copy") }.disabled(
                    !controller.clipboardActionsEnabled)
                Button("Paste to remote") { controller.performClipboard("paste") }.disabled(
                    !controller.clipboardActionsEnabled)
                if !controller.clipboardError.isEmpty { Text(controller.clipboardError) }
            }
            Menu("Video codec") {
                ForEach(Self.options.codecs, id: \.codec) { choice in
                    Button(choice.label) { controller.selectCodec(choice.codec) }
                }
            }
            if !controller.sessionState.codec.isEmpty { Text("Codec: \(controller.sessionState.codec)") }
            if !controller.codecFallbackReason.isEmpty { Text(controller.codecFallbackReason) }
            Button("Refresh screen") { controller.configure(refresh: true) }
        } label: {
            DieterMenuLabel(symbol: "slider.horizontal.3", size: size)
        }
        .dieterMenuChrome(.circle)
        .help("Screen options")
        .accessibilityLabel("Screen options")
    }

}
