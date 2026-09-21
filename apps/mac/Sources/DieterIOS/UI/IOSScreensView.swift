import CoreGraphics

#if os(iOS)
    import DieterAPI
    import DieterCore
    import SwiftUI
    import UIKit
    @preconcurrency import WebRTC

    @MainActor
    struct IOSScreensView: View {
        @Environment(\.dismiss) private var dismiss
        @Environment(\.scenePhase) private var scenePhase
        @Bindable var store: IOSStore
        let backAction: (() -> Void)?
        @State private var session = IOSRemoteDesktopSession()
        @State private var phoneChromeVisible = true
        @State private var phoneSettingsPresented = false
        @State private var showKeyboardAfterSettingsDismissal = false
        @State private var manuallyDisconnected = false
        @State private var clickMode = IOSRemoteDesktopClickMode()

        private var machine: DieterEndpoint? { store.utilityMachine }
        private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

        init(store: IOSStore, backAction: (() -> Void)? = nil) {
            self.store = store
            self.backAction = backAction
        }

        var body: some View {
            VStack(spacing: 0) {
                screenContent
                if isConnected { inputBar }
                statusBar
            }
            .background(Color.black)
            .navigationTitle(machine?.name ?? "Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { screenToolbar }
            .toolbar(isPhone ? .hidden : .visible, for: .navigationBar)
            .overlay { phoneChrome }
            .task(id: machine?.daemonID) {
                session.disconnect()
                manuallyDisconnected = false
                await Task.yield()
                connectIfPossible()
            }
            .onAppear {
                phoneChromeVisible = true
                requestPhoneOrientation(.allButUpsideDown)
            }
            .onDisappear {
                session.disconnect()
                requestPhoneOrientation(.allButUpsideDown)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { connectIfPossible() } else { session.disconnect() }
            }
            .onChange(of: session.phase) { _, phase in
                if phase != .streaming { phoneChromeVisible = true }
            }
            .onChange(of: session.controlActive) { _, active in
                if !active {
                    clickMode.cancel()
                    session.showKeyboard(false)
                }
            }
            .sheet(isPresented: $phoneSettingsPresented, onDismiss: showDeferredKeyboard) {
                phoneSettingsSheet
            }
            .privacySensitive()
        }

        @ViewBuilder private var screenContent: some View {
            switch session.phase {
            case .streaming, .connecting, .waitingForHostApproval, .reconnecting:
                ZStack {
                    Color.black
                    IOSRemoteDesktopSurface(
                        session: session,
                        rightClickArmed: clickMode.rightClickArmed,
                        clickSent: { clickMode.consume() }
                    ) {
                        guard isPhone else { return }
                        withAnimation(.easeInOut(duration: 0.16)) {
                            phoneChromeVisible.toggle()
                        }
                    }
                    if session.phase != .streaming {
                        progressCard(session.phase.label)
                    }
                }
                .accessibilityIdentifier("ios.screens.video")
            case .loading:
                emptyState(
                    title: "Checking \(machine?.name ?? "machine")",
                    detail: "Dieter is checking capture permission and negotiating an authenticated route.",
                    symbol: "ellipsis"
                ) { ProgressView().tint(.white) }
            case .permissionRequired(let reason), .unsupported(let reason):
                emptyState(
                    title: session.phase.label,
                    detail: reason.isEmpty ? "Screen sharing is unavailable on this machine." : reason,
                    symbol: "rectangle.slash"
                ) {
                    Button("Check Again") { connectIfPossible(force: true) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("ios.screens.permissions.retry")
                }
            case .failed(let message):
                emptyState(title: "Couldn’t connect", detail: message, symbol: "exclamationmark.triangle") {
                    Button("Try Again") { connectIfPossible(force: true) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("ios.screens.retry")
                }
            case .idle:
                emptyState(
                    title: machine?.name ?? "Choose a machine",
                    detail: idleDetail,
                    symbol: machine?.online == false ? "wifi.slash" : "display"
                ) {
                    Button("Connect") { connectIfPossible(force: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(machine?.online != true || !store.phase.isConnected)
                        .accessibilityIdentifier("ios.screens.connect")
                }
            }
        }

        private var statusBar: some View {
            HStack(spacing: 7) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(session.phase.label)
                if !session.routeLabel.isEmpty { Text("· \(session.routeLabel)") }
                if !session.sessionState.route.isEmpty { Text("· \(session.sessionState.route)") }
                Spacer(minLength: 8)
                if session.sessionState.width > 0 {
                    Text("\(session.sessionState.width)×\(session.sessionState.height)")
                }
                if session.sessionState.fps > 0 { Text("\(session.sessionState.fps) fps") }
                if session.sessionState.connectedClients > 1 {
                    Text("\(session.sessionState.connectedClients) viewers")
                }
                Label(
                    session.controlActive ? "Control" : "View only",
                    systemImage: session.controlActive ? "cursorarrow.motionlines" : "eye")
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(.bar)
            .accessibilityElement(children: .combine)
        }

        private var inputBar: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if session.canTransferControl {
                        Button {
                            session.transferControl(take: !session.sessionState.controlActive)
                        } label: {
                            Label(
                                session.sessionState.controlActive ? "Release Control" : "Take Control",
                                systemImage: session.sessionState.controlActive
                                    ? "hand.raised" : "cursorarrow.click")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.controlTransferPending)
                        .accessibilityIdentifier("ios.screens.control")
                        if !session.sessionState.controlActive,
                            !session.sessionState.controllerName.isEmpty
                        {
                            Text("\(session.sessionState.controllerName) controls")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if !session.controlActive {
                        Label("View only", systemImage: "eye")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        clickMode.toggleRightClick()
                    } label: {
                        Label(
                            clickMode.rightClickArmed ? "Right click armed" : "Right click",
                            systemImage: "cursorarrow.click")
                    }
                    .buttonStyle(.bordered)
                    .tint(clickMode.rightClickArmed ? .orange : .accentColor)
                    .disabled(!session.controlActive)
                    .accessibilityIdentifier("ios.screens.right-click")
                    .accessibilityHint("Arms one right click for the next tap on the remote screen")

                    Button {
                        session.showKeyboard(!session.keyboardVisible)
                    } label: {
                        Label(session.keyboardVisible ? "Hide Keyboard" : "Keyboard", systemImage: "keyboard")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!session.controlActive)
                    .accessibilityIdentifier("ios.screens.keyboard")

                    inputMenu
                        .buttonStyle(.bordered)
                        .disabled(!session.controlActive)
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
            .background(.bar)
        }

        @ToolbarContentBuilder private var screenToolbar: some ToolbarContent {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !isPhone {
                    machineMenu
                    if session.controlActive {
                        Button("Keyboard", systemImage: "keyboard") { session.showKeyboard(true) }
                            .accessibilityIdentifier("ios.screens.keyboard")
                        inputMenu
                    }
                    optionsMenu
                    if session.canTransferControl {
                        Button(
                            session.sessionState.controlActive ? "Release Control" : "Take Control",
                            systemImage: session.sessionState.controlActive ? "hand.raised" : "cursorarrow.click"
                        ) {
                            session.transferControl(take: !session.sessionState.controlActive)
                        }
                        .disabled(session.controlTransferPending)
                        .accessibilityIdentifier("ios.screens.control")
                    }
                    if isConnected {
                        Button("Disconnect", systemImage: "xmark.circle") { disconnectByUser() }
                            .accessibilityIdentifier("ios.screens.disconnect")
                    }
                }
            }
        }

        @ViewBuilder private var phoneChrome: some View {
            if isPhone, phoneChromeVisible || session.phase != .streaming {
                VStack {
                    HStack {
                        Button {
                            if let backAction { backAction() } else { dismiss() }
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
                            phoneSettingsPresented = true
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
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }

        private var phoneSettingsSheet: some View {
            NavigationStack {
                Form {
                    Section("Machine") { machineMenu }
                    Group { streamSettingsItems }
                        .disabled(!isConnected)
                    if session.controlActive {
                        Section("Input") {
                            Button("Show Keyboard", systemImage: "keyboard") {
                                showKeyboardAfterSettingsDismissal = true
                                phoneSettingsPresented = false
                            }
                            inputMenu
                        }
                    }
                    if session.canTransferControl {
                        Section("Control") {
                            Button(
                                session.sessionState.controlActive ? "Release Control" : "Take Control",
                                systemImage: session.sessionState.controlActive
                                    ? "hand.raised" : "cursorarrow.click"
                            ) {
                                session.transferControl(take: !session.sessionState.controlActive)
                            }
                            .disabled(session.controlTransferPending)
                        }
                    }
                    if isConnected {
                        Section {
                            Button("Disconnect", systemImage: "xmark.circle", role: .destructive) {
                                phoneSettingsPresented = false
                                disconnectByUser()
                            }
                        }
                    }
                }
                .navigationTitle("Stream settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { phoneSettingsPresented = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }

        private var inputMenu: some View {
            Menu("Keys", systemImage: "command") {
                Section("Modifiers") {
                    modifier("Shift", bit: 1)
                    modifier("Control", bit: 2)
                    modifier("Option", bit: 4)
                    modifier("Command", bit: 8)
                }
                Section("Special keys") {
                    Button("Escape") { session.press(hid: 41) }
                    Button("Tab") { session.press(hid: 43) }
                    Button("Return") { session.press(hid: 40) }
                    Button("Delete") { session.press(hid: 42) }
                    Button("Forward Delete") { session.press(hid: 76) }
                    Button("Home") { session.press(hid: 74) }
                    Button("End") { session.press(hid: 77) }
                    Button("Page Up") { session.press(hid: 75) }
                    Button("Page Down") { session.press(hid: 78) }
                    Button("Up") { session.press(hid: 82) }
                    Button("Down") { session.press(hid: 81) }
                    Button("Left") { session.press(hid: 80) }
                    Button("Right") { session.press(hid: 79) }
                }
                Section("Function keys") {
                    ForEach(1...12, id: \.self) { number in
                        Button("F\(number)") { session.press(hid: UInt32(57 + number)) }
                    }
                }
                Divider()
                Button("Release All Input") { session.releaseAllInput() }
            }
            .accessibilityIdentifier("ios.screens.keys")
        }

        private var machineMenu: some View {
            Menu(machine?.name ?? "Choose machine", systemImage: "desktopcomputer") {
                ForEach(store.supportedMachines) { candidate in
                    Button {
                        store.selectUtilityMachine(id: candidate.daemonID ?? candidate.id)
                    } label: {
                        Label(
                            candidate.name + (candidate.online ? "" : " · Offline"),
                            systemImage: candidate.daemonID == store.utilityMachineID
                                ? "checkmark" : "desktopcomputer")
                    }
                    .accessibilityIdentifier("ios.screens.machine.\(candidate.daemonID ?? candidate.id)")
                }
            }
            .accessibilityIdentifier("ios.screens.machine-picker")
        }

        private func modifier(_ title: String, bit: UInt32) -> some View {
            Toggle(
                title,
                isOn: Binding(
                    get: { session.keyboardModifiers & bit != 0 },
                    set: { enabled in
                        if enabled { session.keyboardModifiers |= bit } else { session.keyboardModifiers &= ~bit }
                    }))
        }

        private var optionsMenu: some View {
            Menu("Screen options", systemImage: "slider.horizontal.3") {
                streamSettingsItems
            }
            .disabled(!isConnected)
            .accessibilityIdentifier("ios.screens.options")
        }

        @ViewBuilder private var streamSettingsItems: some View {
            Group {
                if !session.capabilities.displays.isEmpty {
                    Section("Display") {
                        ForEach(session.capabilities.displays, id: \.id) { display in
                            Button(display.name) { session.configure(displayID: display.id) }
                        }
                    }
                }
                Section("Quality") {
                    Button("Automatic") { session.configure(quality: .auto) }
                    Button("Sharp text") { session.configure(quality: .detail) }
                    Button("Responsive motion") { session.configure(quality: .motion) }
                }
                if !session.availableFrameRates.isEmpty {
                    Section("Frame rate") {
                        ForEach(session.availableFrameRates, id: \.self) { rate in
                            Button("Up to \(rate) fps") { session.configure(maxFPS: rate) }
                        }
                    }
                }
                Divider()
                Button("Refresh Screen") { session.configure(refresh: true) }
            }
        }

        private var idleDetail: String {
            guard let machine else { return "Select an enrolled machine from the sidebar first." }
            guard machine.online else { return "This machine is offline." }
            return machine.remoteDesktopReason.isEmpty
                ? "Open an authenticated H.264 screen session with \(machine.name)."
                : machine.remoteDesktopReason
        }

        private var isConnected: Bool {
            switch session.phase {
            case .loading, .connecting, .waitingForHostApproval, .streaming, .reconnecting: true
            default: false
            }
        }

        private var statusColor: Color {
            switch session.phase {
            case .streaming: .green
            case .loading, .connecting, .waitingForHostApproval, .reconnecting: .orange
            case .failed: .red
            default: .secondary
            }
        }

        private func connectIfPossible(force: Bool = false) {
            guard scenePhase == .active, let machine, machine.online, store.phase.isConnected else { return }
            if manuallyDisconnected, !force { return }
            if !force, session.phase != .idle { return }
            manuallyDisconnected = false
            session.connect(machineName: machine.name) { try await store.remoteDesktopConnection() }
        }

        private func disconnectByUser() {
            manuallyDisconnected = true
            session.disconnect()
        }

        private func requestPhoneOrientation(_ orientations: UIInterfaceOrientationMask) {
            guard isPhone,
                let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive })
            else { return }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in }
            scene.windows.first(where: \.isKeyWindow)?.rootViewController?
                .setNeedsUpdateOfSupportedInterfaceOrientations()
        }

        private func showDeferredKeyboard() {
            guard showKeyboardAfterSettingsDismissal else { return }
            showKeyboardAfterSettingsDismissal = false
            guard session.controlActive else { return }
            Task { @MainActor in
                await Task.yield()
                session.showKeyboard(true)
            }
        }

        private func progressCard(_ title: String) -> some View {
            VStack(spacing: 10) {
                ProgressView().tint(.white)
                Text(title).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20).padding(.vertical, 16)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        }

        private func emptyState<Accessory: View>(
            title: String,
            detail: String,
            symbol: String,
            @ViewBuilder accessory: () -> Accessory
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

    struct IOSScreensPlaceholderView: View {
        let open: () -> Void

        var body: some View {
            ContentUnavailableView {
                Label("Remote Screen", systemImage: "display")
            } description: {
                Text("View and control the selected machine over an authenticated screen session.")
            } actions: {
                Button("Open Screen", action: open).buttonStyle(.borderedProminent)
            }
            .navigationTitle("Screens")
        }
    }

    private struct IOSRemoteDesktopSurface: UIViewRepresentable {
        let session: IOSRemoteDesktopSession
        let rightClickArmed: Bool
        let clickSent: () -> Void
        let chromeTapped: () -> Void

        func makeUIView(context: Context) -> IOSRemoteDesktopInputView {
            IOSRemoteDesktopInputView(
                session: session,
                rightClickArmed: rightClickArmed,
                clickSent: clickSent,
                chromeTapped: chromeTapped)
        }

        func updateUIView(_ uiView: IOSRemoteDesktopInputView, context: Context) {
            uiView.use(session: session)
            uiView.rightClickArmed = rightClickArmed
            uiView.clickSent = clickSent
            uiView.chromeTapped = chromeTapped
        }

        static func dismantleUIView(_ uiView: IOSRemoteDesktopInputView, coordinator: ()) {
            uiView.releaseSession()
        }
    }

    @MainActor
    private final class IOSRemoteDesktopInputView: UIView, @preconcurrency RTCVideoViewDelegate, UIKeyInput,
        UIGestureRecognizerDelegate
    {
        private let video = RTCMTLVideoView(frame: .zero)
        private let cursorView = UIImageView(frame: .zero)
        private weak var session: IOSRemoteDesktopSession?
        private var videoSize = CGSize(width: 16, height: 9)
        private var cursorImages: [String: UIImage] = [:]
        private var dragging = false
        private var remoteScrolling = false
        private var zoomScale: CGFloat = 1
        private var zoomOffset = CGPoint.zero
        private var pinchStartScale: CGFloat = 1
        private var pinchAnchor = CGPoint.zero
        private var inputMode = IOSRemoteDesktopInputMode.pointer
        private var inputActivation = 0
        private lazy var suppressedSoftwareKeyboard = UIView(frame: .zero)
        var rightClickArmed: Bool
        var clickSent: () -> Void
        var chromeTapped: () -> Void

        init(
            session: IOSRemoteDesktopSession,
            rightClickArmed: Bool,
            clickSent: @escaping () -> Void,
            chromeTapped: @escaping () -> Void
        ) {
            self.rightClickArmed = rightClickArmed
            self.clickSent = clickSent
            self.chromeTapped = chromeTapped
            super.init(frame: .zero)
            backgroundColor = .black
            clipsToBounds = true
            video.videoContentMode = .scaleAspectFit
            video.isUserInteractionEnabled = false
            video.delegate = self
            addSubview(video)
            cursorView.contentMode = .scaleAspectFit
            cursorView.isUserInteractionEnabled = false
            addSubview(cursorView)
            installGestures()
            accessibilityLabel =
                "Remote screen. Drag one finger to move the pointer, tap to click, hold and move to drag, "
                + "scroll with two fingers, and pinch to zoom."
            use(session: session)
        }

        required init?(coder: NSCoder) { nil }
        override var canBecomeFirstResponder: Bool { true }
        override var inputView: UIView? {
            inputMode.presentsSoftwareKeyboard ? nil : suppressedSoftwareKeyboard
        }
        var hasText: Bool { false }

        func insertText(_ text: String) { session?.text(text) }
        func deleteBackward() { session?.press(hid: 42) }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard sendHardwareKeys(presses, down: true) else {
                super.pressesBegan(presses, with: event)
                return
            }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard sendHardwareKeys(presses, down: false) else {
                super.pressesEnded(presses, with: event)
                return
            }
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            _ = sendHardwareKeys(presses, down: false)
            session?.releaseAllInput()
            super.pressesCancelled(presses, with: event)
        }

        func use(session: IOSRemoteDesktopSession) {
            guard self.session !== session else { return }
            releaseSession()
            self.session = session
            session.attach(renderer: video)
            session.setKeyboardHandler { [weak self] show in
                self?.setTextInputActive(show)
            }
            session.setCursorHandler { [weak self] cursor in self?.updateCursor(cursor) }
            setNeedsLayout()
        }

        func releaseSession() {
            guard let session else { return }
            if dragging { session.button(.left, down: false) }
            dragging = false
            if remoteScrolling { session.scroll(deltaX: 0, deltaY: 0, phase: 4) }
            remoteScrolling = false
            session.releaseAllInput()
            session.detach(renderer: video)
            session.setKeyboardHandler(nil)
            session.setCursorHandler(nil)
            video.renderFrame(nil)
            cursorView.isHidden = true
            zoomScale = 1
            zoomOffset = .zero
            inputMode = .pointer
            _ = resignFirstResponder()
            self.session = nil
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned {
                inputActivation &+= 1
                inputMode = .pointer
                session?.keyboardVisibilityChanged(false)
            }
            return resigned
        }

        private func setTextInputActive(_ active: Bool) {
            inputActivation &+= 1
            let activation = inputActivation
            let nextMode = IOSRemoteDesktopInputMode(textInputActive: active)
            let changed = nextMode != inputMode
            inputMode = nextMode
            if active {
                if isFirstResponder {
                    if changed { reloadInputViews() }
                    session?.keyboardVisibilityChanged(true)
                } else {
                    // A SwiftUI button or a dismissing sheet can restore its own focus
                    // at the end of the current event. Claim input on the next actor turn
                    // so that transient focus restoration cannot immediately hide it.
                    Task { @MainActor [weak self] in
                        await Task.yield()
                        guard let self, self.inputActivation == activation,
                            self.inputMode.presentsSoftwareKeyboard
                        else { return }
                        let focused = self.becomeFirstResponder()
                        if focused, changed { self.reloadInputViews() }
                        self.session?.keyboardVisibilityChanged(focused && self.isFirstResponder)
                    }
                }
            } else {
                if isFirstResponder {
                    _ = resignFirstResponder()
                } else {
                    if changed { reloadInputViews() }
                    session?.keyboardVisibilityChanged(false)
                }
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            zoomOffset = IOSRemoteDesktopGeometry.clampedZoomOffset(
                zoomOffset, bounds: bounds, videoSize: videoSize, zoomScale: zoomScale)
            video.bounds = CGRect(origin: .zero, size: bounds.size)
            video.center = CGPoint(x: bounds.midX + zoomOffset.x, y: bounds.midY + zoomOffset.y)
            video.transform = CGAffineTransform(scaleX: zoomScale, y: zoomScale)
            session?.setViewport(bounds.size, scale: window?.screen.scale ?? UIScreen.main.scale)
            layoutCursor()
        }

        func videoView(_ videoView: any RTCVideoRenderer, didChangeVideoSize size: CGSize) {
            guard size.width > 0, size.height > 0 else { return }
            if size != videoSize {
                zoomScale = 1
                zoomOffset = .zero
            }
            videoSize = size
            session?.videoSizeChanged(size)
            setNeedsLayout()
        }

        private func installGestures() {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.numberOfTapsRequired = 1
            tap.delegate = self
            addGestureRecognizer(tap)

            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
            doubleTap.numberOfTapsRequired = 2
            doubleTap.delegate = self
            tap.require(toFail: doubleTap)
            addGestureRecognizer(doubleTap)

            let pointer = UIPanGestureRecognizer(target: self, action: #selector(pointerMoved(_:)))
            pointer.minimumNumberOfTouches = 1
            pointer.maximumNumberOfTouches = 1
            pointer.delegate = self
            addGestureRecognizer(pointer)

            let drag = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
            drag.minimumPressDuration = 0.35
            drag.allowableMovement = 24
            drag.delegate = self
            tap.require(toFail: drag)
            addGestureRecognizer(drag)

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
            pinch.delegate = self
            addGestureRecognizer(pinch)

            let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
            scroll.minimumNumberOfTouches = 2
            scroll.maximumNumberOfTouches = 2
            scroll.delegate = self
            addGestureRecognizer(scroll)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }

        @objc private func tapped(_ gesture: UITapGestureRecognizer) {
            chromeTapped()
            guard let session, session.controlActive,
                let point = normalized(gesture.location(in: self))
            else { return }
            let button: Dieter_V1_RemoteDesktopPointerButton.Button = rightClickArmed ? .right : .left
            session.pointer(x: point.x, y: point.y)
            session.button(button, down: true, x: point.x, y: point.y, clickCount: 1)
            session.button(button, down: false, x: point.x, y: point.y, clickCount: 1)
            clickSent()
        }

        @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
            chromeTapped()
            guard let session, session.controlActive,
                let point = normalized(gesture.location(in: self))
            else { return }
            let button: Dieter_V1_RemoteDesktopPointerButton.Button = rightClickArmed ? .right : .left
            let clickCount = rightClickArmed ? 1 : 2
            session.pointer(x: point.x, y: point.y)
            session.button(button, down: true, x: point.x, y: point.y, clickCount: clickCount)
            session.button(button, down: false, x: point.x, y: point.y, clickCount: clickCount)
            clickSent()
        }

        @objc private func pointerMoved(_ gesture: UIPanGestureRecognizer) {
            guard let point = normalized(gesture.location(in: self), clamp: true) else { return }
            if gesture.state == .began || gesture.state == .changed {
                session?.pointer(x: point.x, y: point.y)
            }
        }

        @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
            guard let point = normalized(gesture.location(in: self), clamp: true) else { return }
            switch gesture.state {
            case .began:
                dragging = true
                session?.pointer(x: point.x, y: point.y)
                session?.button(.left, down: true, x: point.x, y: point.y)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case .changed:
                session?.pointer(x: point.x, y: point.y)
            case .ended, .cancelled, .failed:
                if dragging { session?.button(.left, down: false, x: point.x, y: point.y) }
                dragging = false
            default:
                break
            }
        }

        @objc private func scrolled(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: self)
            let scale = window?.screen.scale ?? UIScreen.main.scale
            switch gesture.state {
            case .began:
                guard !isPinching else { return }
                remoteScrolling = true
                session?.scroll(deltaX: 0, deltaY: 0, phase: 1)
            case .changed:
                guard remoteScrolling else {
                    gesture.setTranslation(.zero, in: self)
                    return
                }
                if isPinching {
                    session?.scroll(deltaX: 0, deltaY: 0, phase: 4)
                    remoteScrolling = false
                    gesture.setTranslation(.zero, in: self)
                    return
                }
                session?.scroll(deltaX: translation.x / scale, deltaY: translation.y / scale, phase: 2)
                gesture.setTranslation(.zero, in: self)
            case .ended, .cancelled, .failed:
                if remoteScrolling { session?.scroll(deltaX: 0, deltaY: 0, phase: 4) }
                remoteScrolling = false
            default:
                break
            }
        }

        @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
            let location = gesture.location(in: self)
            switch gesture.state {
            case .began:
                if remoteScrolling { session?.scroll(deltaX: 0, deltaY: 0, phase: 4) }
                remoteScrolling = false
                pinchStartScale = zoomScale
                pinchAnchor = IOSRemoteDesktopGeometry.unzoomed(
                    point: location, bounds: bounds, zoomScale: zoomScale, zoomOffset: zoomOffset)
            case .changed:
                zoomScale = IOSRemoteDesktopGeometry.clampedZoomScale(pinchStartScale * gesture.scale)
                zoomOffset = IOSRemoteDesktopGeometry.zoomOffset(
                    keeping: pinchAnchor,
                    at: location,
                    bounds: bounds,
                    videoSize: videoSize,
                    zoomScale: zoomScale)
                setNeedsLayout()
            case .ended, .cancelled, .failed:
                zoomOffset = IOSRemoteDesktopGeometry.clampedZoomOffset(
                    zoomOffset, bounds: bounds, videoSize: videoSize, zoomScale: zoomScale)
                setNeedsLayout()
            default:
                break
            }
        }

        private var isPinching: Bool {
            gestureRecognizers?.contains {
                guard let pinch = $0 as? UIPinchGestureRecognizer else { return false }
                return pinch.state == .began || pinch.state == .changed
            } == true
        }

        private func normalized(_ point: CGPoint, clamp: Bool = false) -> CGPoint? {
            IOSRemoteDesktopGeometry.normalizedDisplayedPoint(
                point,
                bounds: bounds,
                videoSize: videoSize,
                zoomScale: zoomScale,
                zoomOffset: zoomOffset,
                clamp: clamp)
        }

        private func sendHardwareKeys(_ presses: Set<UIPress>, down: Bool) -> Bool {
            guard let session, session.controlActive else { return false }
            var handled = false
            for press in presses {
                guard let key = press.key else { continue }
                session.keyboardModifiers = modifierBits(key.modifierFlags)
                session.key(hid: UInt32(key.keyCode.rawValue), down: down)
                handled = true
            }
            return handled
        }

        private func modifierBits(_ flags: UIKeyModifierFlags) -> UInt32 {
            var bits: UInt32 = 0
            if flags.contains(.shift) { bits |= 1 }
            if flags.contains(.control) { bits |= 2 }
            if flags.contains(.alternate) { bits |= 4 }
            if flags.contains(.command) { bits |= 8 }
            return bits
        }

        private func updateCursor(_ cursor: Dieter_V1_RemoteDesktopCursor) {
            if !cursor.png.isEmpty, cursor.png.count <= 262_144,
                cursor.width > 0, cursor.width <= 256, cursor.height > 0, cursor.height <= 256,
                let image = UIImage(data: cursor.png)
            {
                if cursorImages.count >= 32 { cursorImages.removeAll(keepingCapacity: true) }
                cursorImages[cursor.shapeID] = image
            }
            cursorView.image = cursorImages[cursor.shapeID] ?? UIImage(systemName: "cursorarrow")
            cursorView.isHidden = !cursor.visible || session?.sessionState.embeddedCursor == true
            layoutCursor()
        }

        private func layoutCursor() {
            guard let session, !cursorView.isHidden else { return }
            let cursor = session.cursor
            let content = IOSRemoteDesktopGeometry.contentRect(bounds: bounds, videoSize: videoSize)
            let cursorScale = max(1, window?.screen.scale ?? UIScreen.main.scale) / 2 * zoomScale
            let point = IOSRemoteDesktopGeometry.zoomed(
                point: CGPoint(
                    x: content.minX + content.width * CGFloat(cursor.normalizedX) / 1_000_000,
                    y: content.minY + content.height * CGFloat(cursor.normalizedY) / 1_000_000),
                bounds: bounds,
                zoomScale: zoomScale,
                zoomOffset: zoomOffset)
            let width = max(18, CGFloat(cursor.width) * cursorScale)
            let height = max(18, CGFloat(cursor.height) * cursorScale)
            cursorView.frame = CGRect(
                x: point.x - CGFloat(cursor.hotspotX) * cursorScale,
                y: point.y - CGFloat(cursor.hotspotY) * cursorScale,
                width: width,
                height: height)
        }
    }

#endif

enum IOSRemoteDesktopInputMode: Equatable {
    case pointer
    case text

    init(textInputActive: Bool) {
        self = textInputActive ? .text : .pointer
    }

    var presentsSoftwareKeyboard: Bool { self == .text }
}

struct IOSRemoteDesktopClickMode: Equatable {
    private(set) var rightClickArmed = false

    mutating func toggleRightClick() { rightClickArmed.toggle() }
    mutating func consume() { rightClickArmed = false }
    mutating func cancel() { rightClickArmed = false }
}

enum IOSRemoteDesktopGeometry {
    private static let maximumZoomScale: CGFloat = 4

    static func normalized(
        point: CGPoint,
        bounds: CGRect,
        videoSize: CGSize,
        clamp: Bool = false
    ) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0, videoSize.width > 0, videoSize.height > 0 else {
            return nil
        }
        let content = contentRect(bounds: bounds, videoSize: videoSize)
        guard clamp || content.contains(point) else { return nil }
        return CGPoint(
            x: max(0, min(1, (point.x - content.minX) / content.width)),
            y: max(0, min(1, (point.y - content.minY) / content.height)))
    }

    static func contentRect(bounds: CGRect, videoSize: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return .zero }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height)
    }

    static func clampedZoomScale(_ value: CGFloat) -> CGFloat {
        max(1, min(maximumZoomScale, value))
    }

    static func zoomed(
        point: CGPoint,
        bounds: CGRect,
        zoomScale: CGFloat,
        zoomOffset: CGPoint
    ) -> CGPoint {
        let scale = clampedZoomScale(zoomScale)
        return CGPoint(
            x: bounds.midX + (point.x - bounds.midX) * scale + zoomOffset.x,
            y: bounds.midY + (point.y - bounds.midY) * scale + zoomOffset.y)
    }

    static func unzoomed(
        point: CGPoint,
        bounds: CGRect,
        zoomScale: CGFloat,
        zoomOffset: CGPoint
    ) -> CGPoint {
        let scale = clampedZoomScale(zoomScale)
        return CGPoint(
            x: bounds.midX + (point.x - bounds.midX - zoomOffset.x) / scale,
            y: bounds.midY + (point.y - bounds.midY - zoomOffset.y) / scale)
    }

    static func normalizedDisplayedPoint(
        _ point: CGPoint,
        bounds: CGRect,
        videoSize: CGSize,
        zoomScale: CGFloat,
        zoomOffset: CGPoint,
        clamp: Bool = false
    ) -> CGPoint? {
        normalized(
            point: unzoomed(
                point: point,
                bounds: bounds,
                zoomScale: zoomScale,
                zoomOffset: zoomOffset),
            bounds: bounds,
            videoSize: videoSize,
            clamp: clamp)
    }

    static func zoomOffset(
        keeping contentPoint: CGPoint,
        at displayPoint: CGPoint,
        bounds: CGRect,
        videoSize: CGSize,
        zoomScale: CGFloat
    ) -> CGPoint {
        let scale = clampedZoomScale(zoomScale)
        return clampedZoomOffset(
            CGPoint(
                x: displayPoint.x - bounds.midX - (contentPoint.x - bounds.midX) * scale,
                y: displayPoint.y - bounds.midY - (contentPoint.y - bounds.midY) * scale),
            bounds: bounds,
            videoSize: videoSize,
            zoomScale: scale)
    }

    static func clampedZoomOffset(
        _ offset: CGPoint,
        bounds: CGRect,
        videoSize: CGSize,
        zoomScale: CGFloat
    ) -> CGPoint {
        let content = contentRect(bounds: bounds, videoSize: videoSize)
        let scale = clampedZoomScale(zoomScale)
        let maximumX = max(0, (content.width * scale - bounds.width) / 2)
        let maximumY = max(0, (content.height * scale - bounds.height) / 2)
        return CGPoint(
            x: max(-maximumX, min(maximumX, offset.x)),
            y: max(-maximumY, min(maximumY, offset.y)))
    }
}
