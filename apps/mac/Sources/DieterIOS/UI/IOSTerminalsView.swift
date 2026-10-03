#if os(iOS)
    import DieterAPI
    import DieterShared
    import SharedCore
    @preconcurrency import SwiftTerm
    import SwiftUI
    import UIKit

    /// The machines that can host terminals, as the core lists them; choosing
    /// one opens its terminals in the detail column.
    struct IOSTerminalsMachinePickerView: View {
        @Environment(IOSAppModel.self) private var app
        @Environment(IOSWorkspaceNavigation.self) private var navigation

        private var machines: [ClientMachineEntry] { app.session.machines.filter(\.compatible) }

        var body: some View {
            TimelineView(.periodic(from: .now, by: 30)) { clock in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 7) {
                            Label("Choose where to open a shell", systemImage: "terminal")
                                .font(.title2.bold())
                            Text("Terminals run on one machine and keep running when you leave this screen.")
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
                            .modifier(
                                IOSGlassCardModifier(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
                        } else {
                            ForEach(machines, id: \.id) { machine in
                                row(machine, now: clock.date)
                            }
                        }
                    }
                    .padding(18)
                }
            }
            .background { IOSWorkspaceBackdrop() }
            .navigationTitle("Choose a terminal host")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await app.reconnect() }
            .accessibilityIdentifier("ios.terminals.machine-picker-view")
        }

        private func row(_ machine: ClientMachineEntry, now: Date) -> some View {
            let selected = navigation.terminalMachineID == machine.id
            return Button {
                navigation.openTerminals(machine.id)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "terminal.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(machine.available ? Color.orange : Color.secondary)
                        .frame(width: 48, height: 48)
                        .background(
                            (machine.available ? Color.orange : Color.secondary).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(machine.displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(machine.tone.color)
                                .frame(width: 7, height: 7)
                            Text(app.machineStatus(machine, now: now)).lineLimit(2)
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
            .disabled(!machine.available)
            .modifier(IOSGlassCardModifier(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)))
            .accessibilityHint(machine.unavailableMessage)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("ios.terminals.machine-choice.\(machine.id)")
        }
    }

    /// The detail column before a terminal host is chosen.
    struct IOSTerminalsPlaceholderView: View {
        @Environment(IOSWorkspaceNavigation.self) private var navigation

        var body: some View {
            ContentUnavailableView {
                Label("Choose a terminal host", systemImage: "terminal")
            } description: {
                Text("Pick an enrolled machine before opening a persistent shell.")
            } actions: {
                Button("Choose Machine") { navigation.preferredColumn = .content }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    /// The SwiftTerm view of the selected terminal, which the accessory bar
    /// asks for the terminal's cursor key mode.
    @MainActor
    final class IOSTerminalHandle {
        weak var view: SwiftTerm.TerminalView?
        var applicationCursor: Bool { view?.getTerminal().applicationCursor ?? false }
    }

    /// A machine's persistent terminals, kept by the shared core on that
    /// machine. Only the selected terminal streams while the view is on screen
    /// and the app is active; leaving never ends a shell.
    struct IOSTerminalsView: View {
        @Environment(IOSAppModel.self) private var app
        @Environment(IOSWorkspaceNavigation.self) private var navigation
        @Environment(\.scenePhase) private var scenePhase
        let machineID: String
        @State private var model = TerminalsModel(scope: "ios-terminals-\(UUID().uuidString.lowercased())")
        @State private var handle = IOSTerminalHandle()
        @State private var visible = false
        @State private var renamePresented = false
        @State private var renameValue = ""
        @State private var closeCandidate: Dieter_V1_Terminal?
        @State private var controlArmed = false
        @State private var keyboardDismissRevision = 0

        private var machine: ClientMachineEntry? { app.machine(machineID) }
        private var live: Bool { machine?.available == true }

        var body: some View {
            @Bindable var model = model
            VStack(spacing: 0) {
                terminalTabs
                Divider()
                if let error = model.terminalError, !model.terminals.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("ios.terminals.error")
                }
                terminalContent
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle(machine?.name ?? "Terminals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Choose machine", systemImage: "chevron.left") {
                        navigation.terminalMachineID = nil
                        navigation.preferredColumn = .content
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("ios.terminals.back")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("New terminal", systemImage: "plus") { model.createTerminalPresented = true }
                        .disabled(!live)
                        .accessibilityIdentifier("ios.terminals.new")
                    if let terminal = model.selectedTerminal {
                        Menu("Terminal actions", systemImage: "ellipsis.circle") {
                            Button("Rename…", systemImage: "pencil") {
                                renameValue = terminal.name
                                renamePresented = true
                            }
                            Button("Close terminal…", systemImage: "xmark", role: .destructive) {
                                closeCandidate = terminal
                            }
                        }
                        .accessibilityIdentifier("ios.terminals.actions")
                    }
                }
            }
            .task(id: machineID) {
                model.bind(
                    target: WorkspaceTarget(
                        endpointID: IOSAppModel.endpointID(daemonID: machineID), projectID: ""),
                    core: app.core)
                model.machineName = machine?.name ?? machineID
                model.isLive = live
                visible = true
                updateActive()
                await model.loadTerminals()
            }
            .onDisappear {
                visible = false
                updateActive()
            }
            .onChange(of: scenePhase) { _, _ in updateActive() }
            .onChange(of: live) { _, live in
                model.isLive = live
                if live { Task { await model.loadTerminals() } }
            }
            .onChange(of: model.selectedTerminalID) { _, _ in controlArmed = false }
            .refreshable { await model.loadTerminals() }
            .sheet(isPresented: $model.createTerminalPresented) {
                IOSTerminalCreateView(machineName: machine?.name ?? "Machine") { name, shell, directory in
                    await self.model.createTerminal(name: name, shell: shell, workingDirectory: directory)
                }
            }
            .alert("Rename terminal", isPresented: $renamePresented) {
                TextField("Name", text: $renameValue)
                    .accessibilityIdentifier("ios.terminals.rename-name")
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    guard let id = self.model.selectedTerminalID else { return }
                    let name = renameValue
                    Task { await self.model.renameTerminal(id: id, name: name) }
                }
                .accessibilityIdentifier("ios.terminals.rename-confirm")
            } message: {
                Text("Use a short name that describes what is running in this session.")
            }
            .confirmationDialog(
                "Close \(closeCandidate?.name ?? "terminal")?",
                isPresented: Binding(get: { closeCandidate != nil }, set: { if !$0 { closeCandidate = nil } })
            ) {
                if let terminal = closeCandidate {
                    Button("Close terminal", role: .destructive) {
                        closeCandidate = nil
                        Task { await self.model.closeTerminal(id: terminal.id) }
                    }
                    .accessibilityIdentifier("ios.terminals.close-confirm")
                }
                Button("Cancel", role: .cancel) { closeCandidate = nil }
            } message: {
                Text(closeCandidate.map { model.row($0).closeMessage } ?? "")
            }
            .alert(
                "Terminal",
                isPresented: Binding(
                    get: { model.errorMessage != nil }, set: { if !$0 { self.model.errorMessage = nil } })
            ) {
                Button("OK") { self.model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }

        /// The selected terminal streams while this view shows it and the
        /// app is in the foreground.
        private func updateActive() {
            let active = visible && scenePhase == .active
            if model.active != active { model.active = active }
        }

        @ViewBuilder private var terminalContent: some View {
            if model.terminalLoading, model.terminals.isEmpty {
                ProgressView("Loading persistent terminals…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let terminal = model.selectedTerminal {
                let row = model.row(terminal)
                let running = row.running
                let acceptsInput = row.acceptsInput
                VStack(spacing: 0) {
                    IOSTerminalSurface(
                        terminalID: terminal.id,
                        initialColumns: Int(terminal.columns),
                        initialRows: Int(terminal.rows),
                        screen: model.terminalScreens[terminal.id] ?? TerminalScreenState(),
                        acceptsInput: acceptsInput,
                        controlArmed: controlArmed,
                        keyboardDismissRevision: keyboardDismissRevision,
                        handle: handle,
                        send: { model.sendTerminalInput(id: terminal.id, data: $0) },
                        consumeControl: { controlArmed = false },
                        resize: { columns, rows in
                            Task { await model.resizeTerminal(id: terminal.id, columns: columns, rows: rows) }
                        }
                    )
                    .id(terminal.id)
                    .background(Color(red: 0.035, green: 0.047, blue: 0.055))

                    IOSTerminalAccessoryBar(
                        acceptsInput: acceptsInput,
                        controlArmed: controlArmed,
                        toggleControl: { controlArmed.toggle() },
                        hideKeyboard: { keyboardDismissRevision &+= 1 },
                        sendKey: { send(key: $0, to: terminal.id) },
                        sendText: { send(text: $0, to: terminal.id) }
                    )

                    HStack(spacing: 7) {
                        Circle()
                            .fill(model.row(terminal).tone.color)
                            .frame(width: 7, height: 7)
                        Text(model.row(terminal).status)
                            .accessibilityIdentifier("ios.terminals.status")
                        Spacer(minLength: 8)
                        Text("\(terminal.columns)×\(terminal.rows)")
                        Text("· \(terminal.shell)")
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .background(.bar)
                }
            } else if let error = model.terminalError {
                ContentUnavailableView {
                    Label("Terminals unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await model.loadTerminals() } }
                        .disabled(!live)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("No terminals", systemImage: "terminal")
                } description: {
                    Text("Open a persistent shell on \(machine?.name ?? "this machine").")
                } actions: {
                    Button("Open a terminal") { model.createTerminalPresented = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(!live)
                        .accessibilityIdentifier("ios.terminals.empty-new")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

        private var terminalTabs: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.terminals, id: \.id) { terminal in
                        let selected = model.selectedTerminalID == terminal.id
                        Button {
                            model.selectTerminal(terminal.id)
                        } label: {
                            HStack(spacing: 7) {
                                let row = model.row(terminal)
                                Circle()
                                    .fill(row.running ? Color.green : Color.secondary)
                                    .frame(width: 6, height: 6)
                                Text(terminal.name).lineLimit(1)
                                if !row.running {
                                    Text(row.status).foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                            .background(selected ? Color.orange.opacity(0.16) : .clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("ios.terminals.select.\(terminal.id)")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
            .background(.bar)
            .accessibilityIdentifier("ios.terminals.view")
        }

        // MARK: - Input

        /// A named key, with an armed Control applied as the core encodes it.
        private func send(key: ClientTerminalKey, to terminalID: String) {
            let control = controlArmed
            controlArmed = false
            let bytes = SharedRules.shared.terminalKey(
                key: Int32(key.rawValue), shift: false, alt: false, control: control,
                applicationCursor: handle.applicationCursor)
            model.sendTerminalInput(id: terminalID, data: bytes)
        }

        /// Typed text; an armed Control turns one character into its control code.
        private func send(text: String, to terminalID: String) {
            var bytes = Data(text.utf8)
            if controlArmed, let modified = SharedRules.shared.terminalControl(bytes: bytes) {
                bytes = modified
                controlArmed = false
            }
            model.sendTerminalInput(id: terminalID, data: bytes)
        }
    }

    // MARK: - Accessory bar

    private struct IOSTerminalAccessoryBar: View {
        let acceptsInput: Bool
        let controlArmed: Bool
        let toggleControl: () -> Void
        let hideKeyboard: () -> Void
        let sendKey: (ClientTerminalKey) -> Void
        let sendText: (String) -> Void

        var body: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    key("Esc", identifier: "escape") { sendKey(.escape) }
                    key("Tab", identifier: "tab") { sendKey(.tab) }
                    Button("Ctrl", action: toggleControl)
                        .buttonStyle(IOSTerminalAccessoryKeyStyle(active: controlArmed))
                        .accessibilityLabel(controlArmed ? "Control key armed" : "Control key")
                        .accessibilityHint("Applies Control to the next key")
                        .accessibilityIdentifier("ios.terminals.key.control")

                    Menu {
                        ForEach(1...12, id: \.self) { number in
                            Button("F\(number)") {
                                let key = ClientTerminalKey(
                                    rawValue: Int(SharedRules.shared.terminalFunctionKey(number: Int32(number))))
                                if let key, key != .unspecified { sendKey(key) }
                            }
                        }
                    } label: {
                        Text("F1–12")
                    }
                    .buttonStyle(IOSTerminalAccessoryKeyStyle())
                    .accessibilityIdentifier("ios.terminals.key.function")

                    IOSDirectionalTerminalKey(send: sendKey)

                    key("/", identifier: "slash") { sendText("/") }
                    key(":", identifier: "colon") { sendText(":") }
                    key("−", identifier: "minus") { sendText("-") }
                    key("|", identifier: "pipe") { sendText("|") }
                    key("Return", systemImage: "return", identifier: "return") { sendKey(.enter) }
                    key("Hide keyboard", systemImage: "keyboard.chevron.compact.down", identifier: "hide-keyboard") {
                        hideKeyboard()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
            }
            .background(.bar)
            .disabled(!acceptsInput)
        }

        private func key(
            _ title: String, systemImage: String? = nil, identifier: String, action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                if let systemImage {
                    Image(systemName: systemImage)
                } else {
                    Text(title)
                }
            }
            .buttonStyle(IOSTerminalAccessoryKeyStyle())
            .accessibilityLabel(title)
            .accessibilityIdentifier("ios.terminals.key.\(identifier)")
        }
    }

    private struct IOSTerminalAccessoryKeyStyle: ButtonStyle {
        var active = false
        @Environment(\.isEnabled) private var isEnabled

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(active ? Color.white : Color.primary)
                .frame(minWidth: 44, minHeight: 38)
                .padding(.horizontal, 3)
                .background(
                    active ? Color.orange : Color.primary.opacity(configuration.isPressed ? 0.18 : 0.08),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(active ? Color.orange : Color.secondary.opacity(0.28), lineWidth: 0.75)
                )
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
        }
    }

    /// One key for the four arrows: hold and drag toward a direction; it
    /// repeats while held.
    private struct IOSDirectionalTerminalKey: View {
        let send: (ClientTerminalKey) -> Void
        @State private var activeDirection: ClientTerminalKey?
        @State private var repeatTask: Task<Void, Never>?

        var body: some View {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.body.weight(.semibold))
                .frame(minWidth: 50, minHeight: 38)
                .background(
                    activeDirection == nil ? Color.primary.opacity(0.08) : Color.orange.opacity(0.28),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.secondary.opacity(0.28), lineWidth: 0.75)
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in update(translation: value.translation) }
                        .onEnded { _ in stop() }
                )
                .accessibilityElement()
                .accessibilityLabel("Arrow keys")
                .accessibilityHint("Hold and drag up, down, left, or right")
                .accessibilityIdentifier("ios.terminals.key.arrows")
                .accessibilityAction(named: Text("Up")) { send(.up) }
                .accessibilityAction(named: Text("Down")) { send(.down) }
                .accessibilityAction(named: Text("Left")) { send(.left) }
                .accessibilityAction(named: Text("Right")) { send(.right) }
                .onDisappear { stop() }
        }

        private func update(translation: CGSize) {
            let deadZone: CGFloat = 10
            guard max(abs(translation.width), abs(translation.height)) >= deadZone else { return }
            let direction: ClientTerminalKey =
                abs(translation.width) > abs(translation.height)
                ? (translation.width < 0 ? .left : .right)
                : (translation.height < 0 ? .up : .down)
            guard direction != activeDirection else { return }
            repeatTask?.cancel()
            activeDirection = direction
            send(direction)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            repeatTask = Task { @MainActor in
                do {
                    try await DieterTaskSleep.milliseconds(360)
                    while !Task.isCancelled {
                        send(direction)
                        try await DieterTaskSleep.milliseconds(85)
                    }
                } catch {}
            }
        }

        private func stop() {
            repeatTask?.cancel()
            repeatTask = nil
            activeDirection = nil
        }
    }

    // MARK: - New terminal

    private struct IOSTerminalCreateView: View {
        @Environment(\.dismiss) private var dismiss
        let machineName: String
        let create: (String, String, String) async -> Void
        @State private var name = ""
        @State private var shell = ""
        @State private var directory = ""
        @State private var creating = false

        var body: some View {
            NavigationStack {
                Form {
                    Section("Destination") {
                        Label(machineName, systemImage: "desktopcomputer")
                    }
                    Section("Session") {
                        TextField("Name (optional)", text: $name)
                            .accessibilityIdentifier("ios.terminals.create-name")
                        Picker("Shell", selection: $shell) {
                            Text("System default").tag("")
                            Text("zsh").tag("zsh")
                            Text("bash").tag("bash")
                            Text("fish").tag("fish")
                            Text("sh").tag("sh")
                        }
                        TextField("Starting directory (machine home)", text: $directory)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("ios.terminals.create-directory")
                    }
                    Section {
                        Label(
                            "The shell keeps running when this app disconnects or closes.",
                            systemImage: "lock.shield.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("New terminal")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }.disabled(creating)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Open") {
                            creating = true
                            Task {
                                await create(name, shell, directory)
                                creating = false
                            }
                        }
                        .disabled(creating)
                        .accessibilityIdentifier("ios.terminals.create-confirm")
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .interactiveDismissDisabled(creating)
        }
    }

    // MARK: - Terminal surface

    extension TerminalScreenState {
        /// The latest output as text, for VoiceOver and UI tests.
        fileprivate var accessibilityText: String {
            let limit = 16 * 1_024
            var skip = max(0, byteCount - limit)
            var suffix = Data(capacity: min(limit, byteCount))
            for chunk in chunks {
                if skip >= chunk.count {
                    skip -= chunk.count
                    continue
                }
                suffix.append(chunk.dropFirst(skip))
                skip = 0
            }
            return String(decoding: suffix, as: UTF8.self)
        }
    }

    /// SwiftTerm fed from the core's output; typed bytes go to the core.
    private struct IOSTerminalSurface: UIViewRepresentable {
        let terminalID: String
        let initialColumns: Int
        let initialRows: Int
        let screen: TerminalScreenState
        let acceptsInput: Bool
        let controlArmed: Bool
        let keyboardDismissRevision: Int
        let handle: IOSTerminalHandle
        let send: (Data) -> Void
        let consumeControl: () -> Void
        let resize: (Int, Int) -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(send: send, consumeControl: consumeControl, resize: resize)
        }

        func makeUIView(context: Context) -> SwiftTerm.TerminalView {
            let view = SwiftTerm.TerminalView(
                frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
            view.nativeForegroundColor = UIColor(white: 0.9, alpha: 1)
            view.nativeBackgroundColor = UIColor(red: 0.035, green: 0.047, blue: 0.055, alpha: 1)
            view.caretColor = UIColor.systemOrange
            view.resize(cols: max(2, initialColumns), rows: max(1, initialRows))
            view.terminalDelegate = context.coordinator
            // The SwiftUI key bar replaces SwiftTerm's generic accessory row.
            view.inputAccessoryView = nil
            view.accessibilityIdentifier = "ios.terminals.surface"
            view.accessibilityLabel = "Remote terminal"
            handle.view = view
            context.coordinator.acceptsInput = acceptsInput
            context.coordinator.controlArmed = controlArmed
            context.coordinator.keyboardDismissRevision = keyboardDismissRevision
            context.coordinator.apply(screen, to: view)
            DispatchQueue.main.async { [weak view] in
                if acceptsInput { _ = view?.becomeFirstResponder() }
            }
            return view
        }

        func updateUIView(_ view: SwiftTerm.TerminalView, context: Context) {
            let coordinator = context.coordinator
            handle.view = view
            coordinator.send = send
            coordinator.resize = resize
            coordinator.consumeControl = consumeControl
            coordinator.acceptsInput = acceptsInput
            coordinator.controlArmed = controlArmed
            if coordinator.keyboardDismissRevision != keyboardDismissRevision {
                coordinator.keyboardDismissRevision = keyboardDismissRevision
                _ = view.resignFirstResponder()
            }
            coordinator.apply(screen, to: view)
        }

        static func dismantleUIView(_ view: SwiftTerm.TerminalView, coordinator: Coordinator) {
            coordinator.resizeTask?.cancel()
        }

        @MainActor
        final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
            var send: (Data) -> Void
            var consumeControl: () -> Void
            var resize: (Int, Int) -> Void
            var acceptsInput = false
            var controlArmed = false
            var keyboardDismissRevision = 0
            var resizeTask: Task<Void, Never>?
            private var consumedBytes = 0
            private var resetRevision = -1

            init(
                send: @escaping (Data) -> Void, consumeControl: @escaping () -> Void,
                resize: @escaping (Int, Int) -> Void
            ) {
                self.send = send
                self.consumeControl = consumeControl
                self.resize = resize
            }

            /// Feeds the output SwiftTerm has not drawn; a reset starts over.
            func apply(_ screen: TerminalScreenState, to view: SwiftTerm.TerminalView) {
                let reset = resetRevision != screen.resetRevision || consumedBytes > screen.byteCount
                if reset {
                    let resetSequence: [UInt8] = [0x1b, 0x63]
                    view.feed(byteArray: resetSequence[...])
                    consumedBytes = 0
                    resetRevision = screen.resetRevision
                }
                guard screen.byteCount > consumedBytes else { return }
                var skipped = consumedBytes
                for chunk in screen.chunks {
                    if skipped >= chunk.count {
                        skipped -= chunk.count
                        continue
                    }
                    let bytes = [UInt8](chunk.dropFirst(skipped))
                    skipped = 0
                    if !bytes.isEmpty { view.feed(byteArray: bytes[...]) }
                }
                consumedBytes = screen.byteCount
                view.accessibilityValue = screen.accessibilityText
            }

            func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
                guard acceptsInput else { return }
                let bytes = Data(data)
                if controlArmed, let modified = SharedRules.shared.terminalControl(bytes: bytes) {
                    controlArmed = false
                    consumeControl()
                    send(modified)
                } else {
                    send(bytes)
                }
            }

            func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
                // The core debounces the machine's resize; this only skips layout churn.
                resizeTask?.cancel()
                resizeTask = Task { [weak self] in
                    do { try await DieterTaskSleep.milliseconds(120) } catch { return }
                    self?.resize(newCols, newRows)
                }
            }

            func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
            func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
            func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
            func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
                let resolution = ClientContentLinkResolution(
                    rules: SharedRules.shared.resolveContentLink(url: link, workspaceRoot: "", relativeTo: ""))
                guard case .webURL = resolution.result, let url = URL(string: link) else { return }
                UIApplication.shared.open(url)
            }
            func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
                if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
            }
            func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
        }
    }
#endif
