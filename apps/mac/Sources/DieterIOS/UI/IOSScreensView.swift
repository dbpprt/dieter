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

    /// Draws the decoded screen and the cursor where the shared canvas puts
    /// them, and hands touches, hardware keys, pointer hover, scrolling, and
    /// typed text to the shared touch input. One finger moves the cursor, a
    /// tap clicks, a long press drags, two fingers zoom and pan, and three
    /// fingers scroll.
    @MainActor
    private final class IOSScreenInputView: UIView, UIKeyInput {
        private let controller: IOSScreenController
        private let cursorView = UIImageView(frame: .zero)
        private lazy var noKeyboard = UIView(frame: .zero)
        private var fingers: [ObjectIdentifier: Int32] = [:]
        /// Mouse and trackpad clicks held down, by the button each pressed.
        private var pointerButtons: [ObjectIdentifier: Dieter_V1_RemoteDesktopPointerButton.Button] = [:]
        private var nextFinger: Int32 = 0
        private var longPress: Task<Void, Never>?
        private var softwareKeyboard = false
        private var released = false
        private var canvasSize = CGSize.zero
        private var remoteSize = CGSize.zero
        var keyboardChanged: (Bool) -> Void = { _ in }

        private var touch: SharedTouchScreen { controller.touch }

        init(controller: IOSScreenController) {
            self.controller = controller
            super.init(frame: .zero)
            backgroundColor = .black
            clipsToBounds = true
            isMultipleTouchEnabled = true
            addSubview(controller.renderer)
            cursorView.contentMode = .scaleToFill
            cursorView.isUserInteractionEnabled = false
            cursorView.isHidden = true
            addSubview(cursorView)
            controller.renderer.onVideoSize = { [weak self] _ in self?.setNeedsLayout() }
            isAccessibilityElement = true
            accessibilityLabel = "Remote screen"
            accessibilityHint =
                "One finger moves the pointer and a tap clicks. Hold, then move, to drag. "
                + "Two fingers zoom and pan. Three fingers scroll."
            accessibilityTraits = .allowsDirectInteraction
            installPointerGestures()
            observeController()
        }

        required init?(coder: NSCoder) { nil }

        /// The view went away: held input is released and the renderer stays
        /// with the controller.
        func release() {
            guard !released else { return }
            released = true
            longPress?.cancel()
            if !fingers.isEmpty || !pointerButtons.isEmpty { touch.touchesCancelled() }
            fingers = [:]
            pointerButtons = [:]
            if controller.renderer.superview === self { controller.renderer.removeFromSuperview() }
            controller.renderer.onVideoSize = nil
            _ = resignFirstResponder()
        }

        // MARK: Layout

        override func layoutSubviews() {
            super.layoutSubviews()
            controller.setViewport(bounds.size, scale: window?.screen.scale ?? traitCollection.displayScale)
            applyCanvas()
        }

        /// Places the video and cursor where the shared canvas says.
        private func applyCanvas() {
            guard bounds.width > 0, bounds.height > 0 else { return }
            let remote = currentRemoteSize
            if bounds.size != canvasSize || remote != remoteSize {
                canvasSize = bounds.size
                remoteSize = remote
                touch.resize(
                    viewWidth: bounds.width, viewHeight: bounds.height, remoteWidth: remote.width,
                    remoteHeight: remote.height)
            }
            let zoom = max(touch.zoom, 0.01)
            let renderer = controller.renderer
            renderer.transform = .identity
            renderer.bounds = CGRect(x: 0, y: 0, width: touch.contentWidth / zoom, height: touch.contentHeight / zoom)
            renderer.center = CGPoint(
                x: touch.contentX + touch.contentWidth / 2, y: touch.contentY + touch.contentHeight / 2)
            renderer.transform = CGAffineTransform(scaleX: zoom, y: zoom)
            layoutCursor()
            controller.canvasChanged()
        }

        /// The decoded picture's size, else the stream's, else 16:9.
        private var currentRemoteSize: CGSize {
            let video = controller.renderer.videoSize
            if video.width > 0, video.height > 0 { return video }
            let state = controller.sessionState
            if state.width > 0, state.height > 0 { return CGSize(width: Int(state.width), height: Int(state.height)) }
            return CGSize(width: 1920, height: 1080)
        }

        private func layoutCursor() {
            guard controller.streaming, !controller.sessionState.embeddedCursor else {
                cursorView.isHidden = true
                return
            }
            let x = touch.cursorViewX
            let y = touch.cursorViewY
            let cursor = controller.cursor
            if cursor.visible, let image = controller.cursorImage, cursor.width > 0, cursor.height > 0 {
                // Legible on a phone, and at least the desktop's own size when zoomed in.
                let scale = max(1, touch.contentWidth / max(1, remoteSize.width))
                cursorView.image = image
                cursorView.layer.shadowOpacity = 0
                cursorView.frame = CGRect(
                    x: x - cursor.hotspotX * scale, y: y - cursor.hotspotY * scale, width: cursor.width * scale,
                    height: cursor.height * scale)
            } else {
                cursorView.image = Self.arrow
                cursorView.layer.shadowColor = UIColor.black.cgColor
                cursorView.layer.shadowOpacity = 0.8
                cursorView.layer.shadowRadius = 1
                cursorView.layer.shadowOffset = .zero
                cursorView.frame = CGRect(x: x - 4, y: y - 2, width: 18, height: 22)
            }
            cursorView.isHidden = false
        }

        private static let arrow = UIImage(systemName: "cursorarrow")?
            .withTintColor(.white, renderingMode: .alwaysOriginal)

        /// Re-applies the host cursor, control, and canvas whenever the
        /// controller's slice changes them.
        private func observeController() {
            guard !released else { return }
            withObservationTracking {
                _ = controller.hostCursorRevision
                _ = controller.cursor
                _ = controller.cursorImage
                _ = controller.controlActive
                _ = controller.phase
                _ = controller.canvasRevision
                _ = controller.sessionState
            } onChange: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.controllerChanged()
                        self?.observeController()
                    }
                }
            }
        }

        private func controllerChanged() {
            guard !released else { return }
            // A finger holding the cursor wins over the host's position.
            if !touch.holdingCursor {
                touch.setCursor(x: controller.hostCursor.x, y: controller.hostCursor.y)
            }
            if !controller.controlActive {
                longPress?.cancel()
                if softwareKeyboard { keyboardChanged(false) }
            }
            setNeedsLayout()
        }

        // MARK: Touches

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if controller.controlActive, !isFirstResponder { _ = becomeFirstResponder() }
            let touches = pointerTouches(touches) { pointerDown($0, event: event) }
            guard !touches.isEmpty else { return }
            let first = fingers.isEmpty
            for touch in touches {
                let id = nextFinger
                nextFinger &+= 1
                fingers[ObjectIdentifier(touch)] = id
                let point = touch.location(in: self)
                self.touch.touchDown(id: id, x: point.x, y: point.y, canControl: controller.controlActive)
            }
            if first, fingers.count == 1 { scheduleLongPress() } else { longPress?.cancel() }
            applyCanvas()
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            let touches = pointerTouches(touches) { pointerMoved($0) }
            guard !touches.isEmpty else { return }
            for touch in touches {
                guard let id = fingers[ObjectIdentifier(touch)] else { continue }
                let point = touch.location(in: self)
                self.touch.touchMoved(id: id, x: point.x, y: point.y)
            }
            if !touch.canLongPress { longPress?.cancel() }
            applyCanvas()
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            let touches = pointerTouches(touches) { pointerUp($0) }
            guard !touches.isEmpty else { return }
            for touch in touches {
                guard let id = fingers.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
                let point = touch.location(in: self)
                self.touch.touchUp(id: id, x: point.x, y: point.y, atMillis: Int64(touch.timestamp * 1_000))
            }
            longPress?.cancel()
            applyCanvas()
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            let touches = pointerTouches(touches) { pointerUp($0) }
            guard !touches.isEmpty else { return }
            for touch in touches { fingers.removeValue(forKey: ObjectIdentifier(touch)) }
            longPress?.cancel()
            touch.touchesCancelled()
            fingers = [:]
            applyCanvas()
        }

        // MARK: Mouse and trackpad clicks

        /// Handles the clicks of a mouse or trackpad (indirect pointer
        /// touches) with `handle` and returns the fingers.
        private func pointerTouches(_ touches: Set<UITouch>, handle: (UITouch) -> Void) -> Set<UITouch> {
            var fingers = Set<UITouch>()
            for touch in touches {
                if touch.type == .indirectPointer { handle(touch) } else { fingers.insert(touch) }
            }
            return fingers
        }

        /// A click on the desktop presses its button under the pointer:
        /// the secondary button right-clicks and the third middle-clicks.
        private func pointerDown(_ touch: UITouch, event: UIEvent?) {
            guard controller.controlActive else { return }
            let point = touch.location(in: self)
            guard self.touch.pointAt(x: point.x, y: point.y, clamp: false) else { return }
            let button = Self.button(event?.buttonMask ?? .primary)
            pointerButtons[ObjectIdentifier(touch)] = button
            self.touch.pointerButton(button: Int32(button.rawValue), down: true, clicks: Self.clicks(touch))
            layoutCursor()
        }

        /// A drag keeps the cursor under the pointer, at the desktop's edge
        /// when it leaves.
        private func pointerMoved(_ touch: UITouch) {
            guard pointerButtons[ObjectIdentifier(touch)] != nil else { return }
            let point = touch.location(in: self)
            if self.touch.pointAt(x: point.x, y: point.y, clamp: true) { layoutCursor() }
        }

        private func pointerUp(_ touch: UITouch) {
            guard let button = pointerButtons.removeValue(forKey: ObjectIdentifier(touch)) else { return }
            self.touch.pointerButton(button: Int32(button.rawValue), down: false, clicks: Self.clicks(touch))
        }

        /// A single, double, or triple click.
        private static func clicks(_ touch: UITouch) -> Int32 { Int32(min(3, max(1, touch.tapCount))) }

        private static func button(_ mask: UIEvent.ButtonMask) -> Dieter_V1_RemoteDesktopPointerButton.Button {
            if mask.contains(.secondary) { return .right }
            if mask.contains(.button(3)) { return .middle }
            return .left
        }

        /// A finger held still starts a drag once the system's long-press
        /// time has passed.
        private func scheduleLongPress() {
            longPress?.cancel()
            longPress = Task { @MainActor [weak self] in
                do { try await DieterTaskSleep.milliseconds(400) } catch { return }
                guard let self, !Task.isCancelled, self.touch.canLongPress, self.touch.longPress() else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }

        // MARK: Pointer and scrolling

        private func installPointerGestures() {
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
            hover.cancelsTouchesInView = false
            addGestureRecognizer(hover)

            let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
            scroll.allowedScrollTypesMask = .all
            scroll.allowedTouchTypes = []
            scroll.cancelsTouchesInView = false
            addGestureRecognizer(scroll)
        }

        /// A hardware pointer moves the cursor to the point under it.
        @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
            guard controller.controlActive, gesture.state == .began || gesture.state == .changed else { return }
            let point = gesture.location(in: self)
            if touch.pointAt(x: point.x, y: point.y, clamp: false) { layoutCursor() }
        }

        /// A mouse wheel or trackpad scrolls the host.
        @objc private func scrolled(_ gesture: UIPanGestureRecognizer) {
            guard controller.controlActive else { return }
            let delta = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            switch gesture.state {
            case .began: touch.scroll(dx: 0, dy: 0, phase: 1, momentum: 0)
            case .changed: touch.scroll(dx: delta.x, dy: delta.y, phase: 2, momentum: 0)
            case .ended, .cancelled, .failed: touch.scroll(dx: 0, dy: 0, phase: 4, momentum: 0)
            default: break
            }
        }

        // MARK: Keyboard

        override var canBecomeFirstResponder: Bool { !released }

        /// Without the software keyboard the view still takes hardware keys.
        override var inputView: UIView? { softwareKeyboard ? nil : noKeyboard }

        var hasText: Bool { false }

        func insertText(_ text: String) {
            guard controller.controlActive else { return }
            touch.text(text: text)
        }

        func deleteBackward() {
            guard controller.controlActive else { return }
            touch.press(hid: 42)
        }

        var autocorrectionType: UITextAutocorrectionType {
            get { .no }
            set {}
        }

        var autocapitalizationType: UITextAutocapitalizationType {
            get { .none }
            set {}
        }

        var smartQuotesType: UITextSmartQuotesType {
            get { .no }
            set {}
        }

        var smartDashesType: UITextSmartDashesType {
            get { .no }
            set {}
        }

        var spellCheckingType: UITextSpellCheckingType {
            get { .no }
            set {}
        }

        /// Shows or hides the software keyboard as the toolbar asks.
        func showSoftwareKeyboard(_ shown: Bool) {
            let wanted = shown && controller.controlActive
            guard wanted != softwareKeyboard || (wanted && !isFirstResponder) else { return }
            softwareKeyboard = wanted
            if wanted {
                if isFirstResponder { reloadInputViews() } else { _ = becomeFirstResponder() }
            } else if isFirstResponder {
                reloadInputViews()
            }
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned, softwareKeyboard, !released {
                softwareKeyboard = false
                keyboardChanged(false)
            }
            return resigned
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if !sendKeys(presses, down: true) { super.pressesBegan(presses, with: event) }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if !sendKeys(presses, down: false) { super.pressesEnded(presses, with: event) }
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            _ = sendKeys(presses, down: false)
            super.pressesCancelled(presses, with: event)
        }

        /// Sends hardware keys by HID usage; false when none was sent.
        private func sendKeys(_ presses: Set<UIPress>, down: Bool) -> Bool {
            guard controller.controlActive else { return false }
            var sent = false
            for press in presses {
                guard let key = press.key else { continue }
                touch.key(
                    hid: Int32(truncatingIfNeeded: key.keyCode.rawValue), down: down, repeat: false,
                    modifiers: Self.modifiers(key.modifierFlags))
                sent = true
            }
            return sent
        }

        /// The modifier bits of the screen protocol.
        private static func modifiers(_ flags: UIKeyModifierFlags) -> Int32 {
            var bits: Int32 = 0
            if flags.contains(.shift) { bits |= 1 }
            if flags.contains(.control) { bits |= 2 }
            if flags.contains(.alternate) { bits |= 4 }
            if flags.contains(.command) { bits |= 8 }
            if flags.contains(.alphaShift) { bits |= 16 }
            return bits
        }
    }
#endif
