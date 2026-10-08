#if os(iOS)
    import DieterAPI
    import DieterShared
    import SharedCore
    import SwiftUI
    import UIKit

    /// The machines that can share their screen, as the core lists them;
    /// choosing one opens its screen in the detail column.
    struct IOSScreensMachinePickerView: View {
        @Environment(IOSAppModel.self) private var app
        @Environment(IOSWorkspaceNavigation.self) private var navigation

        private var machines: [ClientMachineEntry] { app.session.machines.filter(\.compatible) }

        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("Choose where to connect", systemImage: "display.2")
                            .font(.title2.bold())
                        Text("Your device becomes the machine’s trackpad and keyboard.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)

                    if machines.isEmpty {
                        ContentUnavailableView(
                            "No compatible machines",
                            systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                            description: Text("Bring an enrolled machine online, then refresh.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 260)
                        .modifier(IOSGlassCardModifier(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
                    } else {
                        ForEach(machines, id: \.id) { row($0) }
                    }
                }
                .padding(18)
            }
            .background { IOSWorkspaceBackdrop() }
            .navigationTitle("Choose a screen")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await app.reconnect() }
            .accessibilityIdentifier("ios.screens.machine-picker-view")
        }

        private func row(_ machine: ClientMachineEntry) -> some View {
            let selected = navigation.screenMachineID == machine.id
            let tint = machine.canShareScreen ? Color.accentColor : Color.secondary
            return Button {
                navigation.openScreen(machine.id)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "desktopcomputer")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 48, height: 48)
                        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(machine.displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(machine.remoteDesktopReady && machine.canShareScreen ? Color.green : Color.orange)
                                .frame(width: 7, height: 7)
                            Text(machine.screenStatus).lineLimit(2)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!machine.canShareScreen)
            .modifier(IOSGlassCardModifier(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("ios.screens.machine-choice.\(machine.id)")
        }
    }

    /// The detail column before a machine is chosen.
    struct IOSScreensPlaceholderView: View {
        @Environment(IOSWorkspaceNavigation.self) private var navigation

        var body: some View {
            ContentUnavailableView {
                Label("Choose a screen", systemImage: "display.2")
            } description: {
                Text("Select the machine you want to view or control.")
            } actions: {
                Button("Choose Machine") { navigation.preferredColumn = .content }
                    .buttonStyle(.borderedProminent)
            }
            .navigationTitle("Screens")
            .background { IOSWorkspaceBackdrop() }
        }
    }

    /// A machine's shared screen: the core's session drawn natively, with
    /// the device as the host's trackpad and keyboard. The session opens
    /// when the view appears and closes when it goes away; the core keeps it
    /// across network changes and restarts it when the app returns.
    struct IOSScreensView: View {
        @Environment(IOSAppModel.self) private var app
        @Environment(IOSWorkspaceNavigation.self) private var navigation
        @Environment(\.scenePhase) private var scenePhase
        let machineID: String
        @State private var controller: IOSScreenController?
        @State private var keyboardShown = false
        @State private var settingsPresented = false
        @State private var manuallyDisconnected = false

        private var machine: ClientMachineEntry? { app.machine(machineID) }
        private var machineName: String {
            guard let machine, !machine.name.isEmpty else { return machineID }
            return machine.name
        }
        private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

        var body: some View {
            Group {
                if let controller {
                    IOSScreenSession(
                        controller: controller, machineName: machineName, machine: machine,
                        keyboardShown: $keyboardShown, connect: { connect(force: true) }
                    )
                    .id(ObjectIdentifier(controller))
                } else {
                    Color.black
                }
            }
            .background(Color.black)
            .navigationTitle(machineName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { padToolbar }
            .toolbar(isPhone ? .hidden : .visible, for: .navigationBar)
            .overlay(alignment: .top) { phoneChrome }
            .sheet(isPresented: $settingsPresented) { settingsSheet }
            .onAppear {
                let session = controller ?? IOSScreenController(core: app.core, media: app.screenMedia)
                controller = session
                connect(force: false, session)
            }
            .onDisappear {
                // A screen that comes back opens a new session and surface.
                controller?.close()
                controller = nil
            }
            .onChange(of: machine?.canShareScreen) { _, _ in connect(force: false) }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: controller?.setForeground(true)
                case .background: controller?.setForeground(false)
                default: break
                }
            }
            .onChange(of: controller?.controlActive) { _, active in
                if active != true { keyboardShown = false }
            }
            .privacySensitive()
        }

        // MARK: Chrome

        @ToolbarContentBuilder private var padToolbar: some ToolbarContent {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !isPhone, let controller {
                    if controller.controlActive {
                        IOSScreenKeysMenu(controller: controller)
                    }
                    Menu("Screen options", systemImage: "slider.horizontal.3") {
                        IOSScreenOptions(controller: controller)
                    }
                    .disabled(!controller.active)
                    .accessibilityIdentifier("ios.screens.options")
                    if controller.active {
                        Button("Disconnect", systemImage: "xmark.circle") { disconnect() }
                            .accessibilityIdentifier("ios.screens.disconnect")
                    }
                }
            }
        }

        @ViewBuilder private var phoneChrome: some View {
            if isPhone {
                HStack {
                    Button {
                        navigation.closeScreen()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline.weight(.semibold))
                            .frame(width: 42, height: 42)
                    }
                    .background(.ultraThinMaterial, in: Circle())
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("ios.screens.back")

                    Spacer()

                    Button {
                        keyboardShown = false
                        settingsPresented = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.headline.weight(.semibold))
                            .frame(width: 42, height: 42)
                    }
                    .background(.ultraThinMaterial, in: Circle())
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stream settings")
                    .accessibilityIdentifier("ios.screens.settings")
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
        }

        private var settingsSheet: some View {
            NavigationStack {
                Form {
                    if let controller {
                        Section("Machine") {
                            Text(machineName).font(.headline)
                            ForEach(controller.session.details, id: \.self) { Text($0) }
                            if !controller.codecFallbackReason.isEmpty {
                                Text(controller.codecFallbackReason).foregroundStyle(.secondary)
                            }
                        }
                        Group { IOSScreenOptions(controller: controller) }
                            .disabled(!controller.active)
                        if controller.active {
                            Section {
                                Button("Disconnect", systemImage: "xmark.circle", role: .destructive) {
                                    settingsPresented = false
                                    disconnect()
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Stream settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { settingsPresented = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }

        // MARK: Session

        /// Connects once the machine can share its screen, unless the person
        /// disconnected; `force` is their own Connect or Try Again.
        private func connect(force: Bool, _ session: IOSScreenController? = nil) {
            guard let controller = session ?? controller, machine?.canShareScreen == true else { return }
            if force {
                manuallyDisconnected = false
            } else if manuallyDisconnected || controller.active || controller.phase != "idle" {
                return
            }
            controller.connect(daemonID: machineID)
        }

        private func disconnect() {
            manuallyDisconnected = true
            keyboardShown = false
            controller?.disconnect()
        }
    }

    /// The screen, its state while not streaming, and the input and status bars.
    private struct IOSScreenSession: View {
        let controller: IOSScreenController
        let machineName: String
        let machine: ClientMachineEntry?
        @Binding var keyboardShown: Bool
        let connect: () -> Void

        var body: some View {
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    IOSScreenSurface(controller: controller, keyboardShown: $keyboardShown)
                        .accessibilityIdentifier("ios.screens.video")
                    if !controller.streaming { stateCard }
                }
                .overlay(alignment: .bottom) {
                    if controller.streaming, !keyboardShown {
                        IOSScreenZoomControls(controller: controller).padding(.bottom, 12)
                    }
                }
                if controller.active { IOSScreenInputBar(controller: controller, keyboardShown: $keyboardShown) }
                IOSScreenStatusBar(controller: controller)
            }
            .background(Color.black)
        }

        @ViewBuilder private var stateCard: some View {
            let message = controller.waitingMessage(machine: machine)
            if controller.active {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(message).font(.subheadline.weight(.semibold))
                    // Why the session is reconnecting, when the core knows.
                    if !controller.problem.isEmpty, controller.problem != message {
                        Text(controller.problem).font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                }
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 16)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
            } else if controller.blocked {
                emptyState(title: controller.phaseLabel, detail: message, symbol: "rectangle.slash") {
                    Button("Check Again", action: connect)
                        .buttonStyle(.borderedProminent)
                        .disabled(machine?.canShareScreen != true)
                        .accessibilityIdentifier("ios.screens.permissions.retry")
                }
            } else if controller.failed {
                emptyState(title: controller.phaseLabel, detail: message, symbol: "exclamationmark.triangle") {
                    Button("Try Again", action: connect)
                        .buttonStyle(.borderedProminent)
                        .disabled(machine?.canShareScreen != true)
                        .accessibilityIdentifier("ios.screens.retry")
                }
            } else {
                emptyState(
                    title: machineName, detail: message, symbol: machine?.online == false ? "wifi.slash" : "display"
                ) {
                    Button("Connect", action: connect)
                        .buttonStyle(.borderedProminent)
                        .disabled(machine?.canShareScreen != true)
                        .accessibilityIdentifier("ios.screens.connect")
                }
            }
        }

        private func emptyState<Accessory: View>(
            title: String, detail: String, symbol: String, @ViewBuilder accessory: () -> Accessory
        ) -> some View {
            ContentUnavailableView {
                Label(title, systemImage: symbol)
            } description: {
                Text(detail)
            } actions: {
                accessory()
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        }
    }

    /// Control, right click, the keyboard, and the toolbar keys.
    private struct IOSScreenInputBar: View {
        let controller: IOSScreenController
        @Binding var keyboardShown: Bool

        var body: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if controller.canTransferControl {
                        Button {
                            controller.transferControl(take: !controller.controlActive)
                        } label: {
                            Label(
                                SharedRules.shared.screenControlAction(controlActive: controller.controlActive),
                                systemImage: controller.controlActive ? "hand.raised" : "cursorarrow.click")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.controlTransferring)
                        .accessibilityIdentifier("ios.screens.control")
                        if !controller.controlActive, !controller.sessionState.controllerName.isEmpty {
                            Text("\(controller.sessionState.controllerName) controls")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if !controller.controlActive {
                        Label("View only", systemImage: "eye").foregroundStyle(.secondary)
                    }
                    if !controller.controlUnavailableReason.isEmpty {
                        Text(controller.controlUnavailableReason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !controller.controlError.isEmpty {
                        Text(controller.controlError).font(.caption).foregroundStyle(.orange)
                    }

                    Button {
                        controller.toggleRightClick()
                    } label: {
                        Label(
                            controller.rightClickArmed ? "Right click armed" : "Right click",
                            systemImage: "cursorarrow.click.2")
                    }
                    .buttonStyle(.bordered)
                    .tint(controller.rightClickArmed ? .orange : .accentColor)
                    .disabled(!controller.controlActive)
                    .accessibilityIdentifier("ios.screens.right-click")
                    .accessibilityHint("Arms one right click for the next tap on the remote screen")

                    Button {
                        keyboardShown.toggle()
                    } label: {
                        Label(keyboardShown ? "Hide Keyboard" : "Keyboard", systemImage: "keyboard")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!controller.controlActive)
                    .accessibilityIdentifier("ios.screens.keyboard")

                    IOSScreenKeysMenu(controller: controller)
                        .buttonStyle(.bordered)
                        .disabled(!controller.controlActive)
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
            .background(.bar)
        }
    }

    /// The core's toolbar keys: modifiers armed for the next key or text, and
    /// special keys pressed with them.
    private struct IOSScreenKeysMenu: View {
        let controller: IOSScreenController

        private static let keys: ClientScreenToolbarKeys =
            (try? ClientScreenToolbarKeys(serializedBytes: SharedRules.shared.screenToolbarKeys())) ?? .init()

        var body: some View {
            Menu("Keys", systemImage: "command") {
                Section("Modifiers") {
                    ForEach(Self.keys.modifiers, id: \.hid) { key in
                        let armed = controller.armedModifiers & key.modifier != 0
                        let toggle = Binding(get: { armed }, set: { _ in controller.toggleModifier(key.modifier) })
                        Toggle(key.label, isOn: toggle)
                            .accessibilityLabel(armed ? "\(key.label) modifier armed" : "\(key.label) modifier")
                            .accessibilityHint("Applies to the next key")
                    }
                }
                Section("Keys") {
                    ForEach(Self.keys.special, id: \.hid) { key in
                        Button(key.label) { controller.press(hid: key.hid) }
                    }
                }
                Divider()
                Button("Release All Input") { controller.releaseInput() }
            }
            .accessibilityIdentifier("ios.screens.keys")
        }
    }

    /// The display, quality, codec, and frame rate choices, and refresh.
    private struct IOSScreenOptions: View {
        let controller: IOSScreenController

        /// The core's quality and codec choices, in menu order.
        private static let options: ClientScreenStreamOptions =
            (try? ClientScreenStreamOptions(serializedBytes: SharedRules.shared.screenStreamOptions())) ?? .init()

        var body: some View {
            if !controller.capabilities.displays.isEmpty {
                Section("Display") {
                    ForEach(controller.capabilities.displays, id: \.id) { display in
                        Button {
                            controller.selectDisplay(display.id)
                        } label: {
                            Label(
                                display.name.isEmpty ? display.id : display.name,
                                systemImage: controller.sessionState.displayID == display.id ? "checkmark" : "display")
                        }
                    }
                }
            }
            Section("Quality") {
                ForEach(Self.options.qualities, id: \.quality) { choice in
                    option(choice.label, selected: controller.preferences.quality == choice.quality) {
                        controller.selectQuality(choice.quality)
                    }
                }
            }
            Section("Codec") {
                ForEach(Self.options.codecs, id: \.codec) { choice in
                    option(choice.label, selected: controller.preferences.codec == choice.codec) {
                        controller.selectCodec(choice.codec)
                    }
                }
            }
            if !controller.frameRates.isEmpty {
                Section("Frame rate") {
                    ForEach(controller.frameRates, id: \.self) { rate in
                        option(
                            SharedRules.shared.screenFrameRate(fps: rate),
                            selected: controller.preferences.maxFps == rate
                        ) {
                            controller.selectFrameRate(rate)
                        }
                    }
                }
            }
            if controller.capabilities.clipboardSupported {
                Section("Clipboard") {
                    Toggle(
                        "Share clipboard",
                        isOn: Binding(
                            get: { controller.clipboardEnabled }, set: { controller.setClipboardEnabled($0) })
                    )
                    .disabled(!controller.controlActive)
                    Button("Copy on host") { controller.performClipboard("copy") }
                        .disabled(!controller.clipboardActionsEnabled)
                    Button("Paste to host") { controller.performClipboard("paste") }
                        .disabled(!controller.clipboardActionsEnabled)
                    if !controller.clipboardError.isEmpty {
                        Text(controller.clipboardError).foregroundStyle(.orange)
                    }
                }
            }
            Button("Refresh Screen", systemImage: "arrow.clockwise") { controller.refresh() }
        }

        private func option(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
            }
        }
    }

    /// Zoom out, fit, and zoom in around the view's center.
    private struct IOSScreenZoomControls: View {
        let controller: IOSScreenController

        var body: some View {
            HStack(spacing: 4) {
                Button("Zoom out", systemImage: "minus") { controller.zoom(by: 1 / 1.25) }
                    .labelStyle(.iconOnly)
                    .disabled(controller.zoom <= controller.minimumZoom + 0.001)
                    .accessibilityIdentifier("ios.screens.zoom-out")
                Button {
                    controller.fit()
                } label: {
                    Label(
                        controller.fitted ? "Fit · 100%" : "\(Int((controller.zoom * 100).rounded()))%",
                        systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .frame(minWidth: 110)
                .accessibilityLabel("Fit screen")
                .accessibilityValue("\(Int((controller.zoom * 100).rounded())) percent")
                .accessibilityIdentifier("ios.screens.fit")
                Button("Zoom in", systemImage: "plus") { controller.zoom(by: 1.25) }
                    .labelStyle(.iconOnly)
                    .disabled(controller.zoom >= controller.maximumZoom - 0.001)
                    .accessibilityIdentifier("ios.screens.zoom-in")
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// The phase, routes, size, rate, viewers, latency, and control state.
    private struct IOSScreenStatusBar: View {
        let controller: IOSScreenController

        var body: some View {
            HStack(spacing: 7) {
                Circle().fill(controller.session.tone.color).frame(width: 7, height: 7)
                Text(controller.phaseLabel)
                if !controller.routeLabel.isEmpty { Text("· \(controller.routeLabel)") }
                Spacer(minLength: 8)
                if controller.streaming {
                    Text(controller.session.metadata)
                    if !controller.session.viewersLabel.isEmpty { Text(controller.session.viewersLabel) }
                    Text(controller.latencyLabel)
                }
                Label(
                    controller.session.controlLabel,
                    systemImage: controller.controlActive ? "cursorarrow.motionlines" : "eye")
            }
            .lineLimit(1)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(.bar)
            .accessibilityElement(children: .combine)
        }

    }

    #if DEBUG
        /// The isolated UI tests' real-media screen: the core signals through
        /// the native fixture and the shared engine decodes into the UIKit
        /// renderer. "Live" proves at least one frame was presented.
        struct IOSScreenFixtureView: View {
            @State private var controller = IOSScreenController(
                core: IOSAppModel.live.core, media: IOSAppModel.live.screenMedia)

            var body: some View {
                ZStack {
                    Color.black.ignoresSafeArea()
                    IOSScreenSurface(controller: controller, keyboardShown: .constant(false))
                        .accessibilityIdentifier("ios.screens.fixture")
                    if !controller.streaming {
                        VStack(spacing: 12) {
                            if controller.active {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            }
                            Text(controller.phaseLabel).font(.headline)
                            if !controller.problem.isEmpty {
                                Text(controller.problem)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(20)
                        .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    Text(controller.phaseLabel)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(controller.streaming ? .green : .orange)
                        .padding(10)
                        .background(.black.opacity(0.72), in: Capsule())
                        .padding(12)
                        .accessibilityIdentifier("ios.screens.fixture.phase")
                }
                .onAppear { controller.connect(daemonID: "fixture") }
                .onDisappear { controller.close() }
            }
        }
    #endif

    // MARK: - Surface

    /// The screen's UIKit view: video, cursor, touches, keys, and text.
    private struct IOSScreenSurface: UIViewRepresentable {
        let controller: IOSScreenController
        @Binding var keyboardShown: Bool

        func makeUIView(context: Context) -> IOSScreenInputView {
            IOSScreenInputView(controller: controller)
        }

        func updateUIView(_ view: IOSScreenInputView, context: Context) {
            view.keyboardChanged = { shown in
                if keyboardShown != shown { keyboardShown = shown }
            }
            view.showSoftwareKeyboard(keyboardShown)
        }

        static func dismantleUIView(_ view: IOSScreenInputView, coordinator: ()) {
            view.release()
        }
    }

#endif
