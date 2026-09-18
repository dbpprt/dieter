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
        @State private var manuallyDisconnected = false

        private var machine: DieterEndpoint? { store.selectedMachine }
        private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

        init(store: IOSStore, backAction: (() -> Void)? = nil) {
            self.store = store
            self.backAction = backAction
        }

        var body: some View {
            VStack(spacing: 0) {
                screenContent
                statusBar
            }
            .background(Color.black)
            .navigationTitle(machine?.name ?? "Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { screenToolbar }
            .toolbar(isPhone ? .hidden : .visible, for: .navigationBar)
            .overlay { phoneChrome }
            .task(id: machine?.daemonID) {
                manuallyDisconnected = false
                connectIfPossible()
            }
            .onAppear {
                phoneChromeVisible = true
                requestPhoneOrientation(.landscape)
            }
            .onDisappear {
                session.disconnect()
                requestPhoneOrientation(.portrait)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { connectIfPossible() } else { session.disconnect() }
            }
            .onChange(of: session.phase) { _, phase in
                if phase != .streaming { phoneChromeVisible = true }
            }
            .onChange(
                of: CGSize(
                    width: CGFloat(session.sessionState.width),
                    height: CGFloat(session.sessionState.height))
            ) { _, remoteSize in
                followRemoteOrientation(remoteSize)
            }
            .onChange(of: session.videoSize) { _, videoSize in
                followRemoteOrientation(videoSize)
            }
            .alert(
                "Clipboard",
                isPresented: Binding(
                    get: { !session.clipboardError.isEmpty },
                    set: { if !$0 { session.clipboardError = "" } })
            ) {
                Button("OK") { session.clipboardError = "" }
            } message: {
                Text(session.clipboardError)
            }
            .sheet(isPresented: $phoneSettingsPresented) { phoneSettingsSheet }
            .privacySensitive()
        }

        @ViewBuilder private var screenContent: some View {
            switch session.phase {
            case .streaming, .connecting, .reconnecting:
                ZStack {
                    Color.black
                    IOSRemoteDesktopSurface(session: session) {
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
            case .disabled(let reason):
                emptyState(
                    title: "Screen sharing is off",
                    detail: reason.isEmpty ? "Enable screen sharing on this machine to continue." : reason,
                    symbol: "rectangle.slash"
                ) {
                    Button("Enable & Connect") { session.enableAndConnect() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("ios.screens.enable")
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
                if !session.clipboardNotice.isEmpty { Text("· \(session.clipboardNotice)") }
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(.bar)
            .accessibilityElement(children: .combine)
        }

        @ToolbarContentBuilder private var screenToolbar: some ToolbarContent {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !isPhone {
                    if session.controlActive {
                        Button("Keyboard", systemImage: "keyboard") { session.showKeyboard(true) }
                            .accessibilityIdentifier("ios.screens.keyboard")
                        inputMenu
                    }
                    if session.clipboardAvailable { clipboardMenu }
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
                    Group { streamSettingsItems }
                        .disabled(!isConnected)
                    if session.controlActive {
                        Section("Input") {
                            Button("Show Keyboard", systemImage: "keyboard") { session.showKeyboard(true) }
                            inputMenu
                        }
                    }
                    if session.clipboardAvailable {
                        Section("Clipboard") { clipboardItems }
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
                    Button("Up") { session.press(hid: 82) }
                    Button("Down") { session.press(hid: 81) }
                    Button("Left") { session.press(hid: 80) }
                    Button("Right") { session.press(hid: 79) }
                }
                Divider()
                Button("Right Click") { session.click(.right) }
                Button("Release All Input") { session.releaseAllInput() }
            }
            .accessibilityIdentifier("ios.screens.keys")
        }

        private var clipboardMenu: some View {
            Menu("Clipboard", systemImage: "doc.on.clipboard") {
                clipboardItems
            }
            .accessibilityIdentifier("ios.screens.clipboard")
        }

        @ViewBuilder private var clipboardItems: some View {
            Button("Copy Remote Selection", systemImage: "doc.on.doc") {
                session.copyRemoteSelection()
            }
            .disabled(session.clipboardBusy)
            .accessibilityIdentifier("ios.screens.clipboard.copy")
            PasteButton(payloadType: String.self) { values in
                session.pasteText(values)
            }
            .disabled(session.clipboardBusy)
            .accessibilityIdentifier("ios.screens.clipboard.paste")
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
            case .loading, .connecting, .streaming, .reconnecting: true
            default: false
            }
        }

        private var statusColor: Color {
            switch session.phase {
            case .streaming: .green
            case .loading, .connecting, .reconnecting: .orange
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

        private func followRemoteOrientation(_ remoteSize: CGSize) {
            guard let portrait = IOSRemoteDesktopOrientation.isPortrait(remoteSize) else { return }
            requestPhoneOrientation(portrait ? .portrait : .landscape)
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
        let chromeTapped: () -> Void

        func makeUIView(context: Context) -> IOSRemoteDesktopInputView {
            IOSRemoteDesktopInputView(session: session, chromeTapped: chromeTapped)
        }

        func updateUIView(_ uiView: IOSRemoteDesktopInputView, context: Context) {
            uiView.use(session: session)
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
        var chromeTapped: () -> Void

        init(session: IOSRemoteDesktopSession, chromeTapped: @escaping () -> Void) {
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
                "Remote screen. Drag one finger to move the pointer, tap to click, hold and move to drag, and scroll with two fingers."
            use(session: session)
        }

        required init?(coder: NSCoder) { nil }
        override var canBecomeFirstResponder: Bool { true }
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
                if show { self?.becomeFirstResponder() } else { self?.resignFirstResponder() }
            }
            session.setCursorHandler { [weak self] cursor in self?.updateCursor(cursor) }
            setNeedsLayout()
        }

        func releaseSession() {
            guard let session else { return }
            if dragging { session.button(.left, down: false) }
            dragging = false
            session.releaseAllInput()
            session.detach(renderer: video)
            session.setKeyboardHandler(nil)
            session.setCursorHandler(nil)
            video.renderFrame(nil)
            cursorView.isHidden = true
            resignFirstResponder()
            self.session = nil
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            video.frame = bounds
            session?.setViewport(bounds.size, scale: window?.screen.scale ?? UIScreen.main.scale)
            layoutCursor()
        }

        func videoView(_ videoView: any RTCVideoRenderer, didChangeVideoSize size: CGSize) {
            guard size.width > 0, size.height > 0 else { return }
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
            guard let point = normalized(gesture.location(in: self)) else { return }
            becomeFirstResponder()
            session?.pointer(x: point.x, y: point.y)
            session?.button(.left, down: true, x: point.x, y: point.y, clickCount: 1)
            session?.button(.left, down: false, x: point.x, y: point.y, clickCount: 1)
        }

        @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
            chromeTapped()
            guard let point = normalized(gesture.location(in: self)) else { return }
            becomeFirstResponder()
            session?.pointer(x: point.x, y: point.y)
            session?.button(.left, down: true, x: point.x, y: point.y, clickCount: 2)
            session?.button(.left, down: false, x: point.x, y: point.y, clickCount: 2)
        }

        @objc private func pointerMoved(_ gesture: UIPanGestureRecognizer) {
            guard let point = normalized(gesture.location(in: self), clamp: true) else { return }
            if gesture.state == .began { becomeFirstResponder() }
            if gesture.state == .began || gesture.state == .changed {
                session?.pointer(x: point.x, y: point.y)
            }
        }

        @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
            guard let point = normalized(gesture.location(in: self), clamp: true) else { return }
            switch gesture.state {
            case .began:
                becomeFirstResponder()
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
                session?.scroll(deltaX: 0, deltaY: 0, phase: 1)
            case .changed:
                session?.scroll(deltaX: translation.x / scale, deltaY: translation.y / scale, phase: 2)
                gesture.setTranslation(.zero, in: self)
            case .ended, .cancelled, .failed:
                session?.scroll(deltaX: 0, deltaY: 0, phase: 4)
            default:
                break
            }
        }

        private func normalized(_ point: CGPoint, clamp: Bool = false) -> CGPoint? {
            IOSRemoteDesktopGeometry.normalized(point: point, bounds: bounds, videoSize: videoSize, clamp: clamp)
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
            let scale = max(1, window?.screen.scale ?? UIScreen.main.scale) / 2
            let width = max(18, CGFloat(cursor.width) * scale)
            let height = max(18, CGFloat(cursor.height) * scale)
            cursorView.frame = CGRect(
                x: content.minX + content.width * CGFloat(cursor.normalizedX) / 1_000_000
                    - CGFloat(cursor.hotspotX) * scale,
                y: content.minY + content.height * CGFloat(cursor.normalizedY) / 1_000_000
                    - CGFloat(cursor.hotspotY) * scale,
                width: width,
                height: height)
        }
    }

#endif

enum IOSRemoteDesktopOrientation {
    static func isPortrait(_ remoteSize: CGSize) -> Bool? {
        guard remoteSize.width > 0, remoteSize.height > 0 else { return nil }
        return remoteSize.height > remoteSize.width
    }
}

enum IOSRemoteDesktopGeometry {
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
}
