#if os(iOS)
    import DieterAPI
    import DieterCore
    @preconcurrency import SwiftTerm
    import SwiftUI
    import UIKit

    @MainActor
    struct IOSTerminalsMachinePickerView: View {
        @Bindable var store: IOSStore
        let select: (String) -> Void

        private var machines: [DieterEndpoint] {
            store.supportedMachines.sorted {
                if $0.online != $1.online { return $0.online && !$1.online }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }

        var body: some View {
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
                            IOSGlassCardModifier(
                                shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
                    } else {
                        ForEach(machines) { machine in
                            Button {
                                select(machine.daemonID ?? machine.id)
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "terminal.fill")
                                        .font(.title2.weight(.semibold))
                                        .foregroundStyle(machine.online ? Color.orange : Color.secondary)
                                        .frame(width: 48, height: 48)
                                        .background(
                                            (machine.online ? Color.orange : Color.secondary).opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(machine.name).font(.headline).foregroundStyle(.primary)
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(machine.online ? Color.green : Color.orange)
                                                .frame(width: 7, height: 7)
                                            Text(
                                                machine.online
                                                    ? "Persistent machine-home shells"
                                                    : MachinePresenceText.lastSeen(machine.lastSeenAt))
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
                            .disabled(!machine.online || !store.phase.isConnected)
                            .modifier(
                                IOSGlassCardModifier(
                                    shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            )
                            .accessibilityIdentifier(
                                "ios.terminals.machine-choice.\(machine.daemonID ?? machine.id)")
                        }
                    }
                }
                .padding(18)
            }
            .background { IOSWorkspaceBackdrop() }
            .navigationTitle("Choose a terminal host")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refreshMachines() }
            .accessibilityIdentifier("ios.terminals.machine-picker-view")
        }
    }

    @MainActor
    struct IOSTerminalsView: View {
        @Bindable var store: IOSStore
        let backAction: (() -> Void)?
        @State private var model = IOSTerminalsModel()
        @State private var createPresented = false
        @State private var renamePresented = false
        @State private var renameValue = ""
        @State private var closeCandidate: Dieter_V1_Terminal?
        @State private var controlArmed = false
        @State private var keyboardDismissRevision = 0

        private var machine: DieterEndpoint? { store.utilityMachine }

        init(store: IOSStore, backAction: (() -> Void)? = nil) {
            self.store = store
            self.backAction = backAction
        }

        var body: some View {
            VStack(spacing: 0) {
                terminalTabs
                Divider()
                terminalContent
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle(machine?.name ?? "Terminals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let backAction {
                        Button("Choose machine", systemImage: "chevron.left", action: backAction)
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("ios.terminals.back")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("New terminal", systemImage: "plus") { createPresented = true }
                        .disabled(machine?.online != true || !store.phase.isConnected)
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
            .task(id: machine?.daemonID) {
                model.disconnect(clear: true)
                guard let machine else { return }
                model.connect(machineName: machine.name) {
                    try await store.utilityTerminalConnection()
                }
            }
            .onDisappear { model.disconnect() }
            .refreshable { model.refresh() }
            .sheet(isPresented: $createPresented) {
                IOSTerminalCreateView(machineName: machine?.name ?? "Machine") { name, shell, directory in
                    let created = await model.create(name: name, shell: shell, workingDirectory: directory)
                    if created { createPresented = false }
                }
            }
            .alert("Rename terminal", isPresented: $renamePresented) {
                TextField("Name", text: $renameValue)
                    .accessibilityIdentifier("ios.terminals.rename-name")
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    guard let id = model.selectedTerminalID else { return }
                    Task { await model.rename(id: id, name: renameValue) }
                }
                .accessibilityIdentifier("ios.terminals.rename-confirm")
            } message: {
                Text("Use a short name that describes what is running in this session.")
            }
            .confirmationDialog(
                "Close \(closeCandidate?.name ?? "terminal")?",
                isPresented: Binding(
                    get: { closeCandidate != nil },
                    set: { if !$0 { closeCandidate = nil } })
            ) {
                if let terminal = closeCandidate {
                    Button("Close terminal", role: .destructive) {
                        closeCandidate = nil
                        Task { await model.close(id: terminal.id) }
                    }
                    .accessibilityIdentifier("ios.terminals.close-confirm")
                }
                Button("Cancel", role: .cancel) { closeCandidate = nil }
            } message: {
                Text(
                    closeCandidate?.status == "running"
                        ? "This explicitly ends the daemon-owned shell. Leaving this screen does not."
                        : "This removes the finished session and its scrollback.")
            }
            .alert(
                "Terminal",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } })
            ) {
                Button("OK") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }

        @ViewBuilder private var terminalContent: some View {
            if model.loading, model.terminals.isEmpty {
                ProgressView("Loading persistent terminals…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let terminal = model.selectedTerminal {
                VStack(spacing: 0) {
                    IOSTerminalSurface(
                        terminalID: terminal.id,
                        initialColumns: Int(terminal.columns),
                        initialRows: Int(terminal.rows),
                        screen: model.screens[terminal.id] ?? IOSTerminalScreenState(),
                        acceptsInput: terminal.status == "running" && model.streamConnected,
                        controlArmed: controlArmed,
                        keyboardDismissRevision: keyboardDismissRevision,
                        send: { model.send(id: terminal.id, data: $0) },
                        consumeControl: { controlArmed = false },
                        resize: { columns, rows in
                            Task { await model.resize(id: terminal.id, columns: columns, rows: rows) }
                        }
                    )
                    .id(terminal.id)
                    .background(Color(red: 0.035, green: 0.047, blue: 0.055))

                    IOSTerminalAccessoryBar(
                        acceptsInput: terminal.status == "running" && model.streamConnected,
                        controlArmed: controlArmed,
                        toggleControl: { controlArmed.toggle() },
                        hideKeyboard: { keyboardDismissRevision &+= 1 },
                        send: { data, appliesControl in
                            var payload = data
                            if appliesControl, controlArmed,
                                let modified = IOSTerminalKeyInput.controlModified(data)
                            {
                                payload = modified
                                controlArmed = false
                            }
                            model.send(id: terminal.id, data: payload)
                        }
                    )

                    HStack(spacing: 7) {
                        Circle()
                            .fill(statusColor(terminal))
                            .frame(width: 7, height: 7)
                        Text(statusText(terminal))
                        if !model.routeLabel.isEmpty { Text("· \(model.routeLabel)") }
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
            } else {
                ContentUnavailableView {
                    Label("No terminals", systemImage: "terminal")
                } description: {
                    Text("Open a persistent shell on \(machine?.name ?? "this machine").")
                } actions: {
                    Button("Open a terminal") { createPresented = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(machine?.online != true || !store.phase.isConnected)
                        .accessibilityIdentifier("ios.terminals.empty-new")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

        private var terminalTabs: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.terminals, id: \.id) { terminal in
                        Button {
                            controlArmed = false
                            model.select(terminal.id)
                        } label: {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(terminal.status == "running" ? Color.green : Color.secondary)
                                    .frame(width: 6, height: 6)
                                Text(terminal.name).lineLimit(1)
                                if terminal.status != "running" {
                                    Text("exited").foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption.weight(model.selectedTerminalID == terminal.id ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                            .background(
                                model.selectedTerminalID == terminal.id ? Color.orange.opacity(0.16) : .clear,
                                in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("ios.terminals.select.\(terminal.id)")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
            .background(.bar)
            .accessibilityIdentifier("ios.terminals.view")
        }

        private func statusColor(_ terminal: Dieter_V1_Terminal) -> SwiftUI.Color {
            if terminal.status != "running" { return terminal.hasExitCode && terminal.exitCode == 0 ? .gray : .red }
            return model.streamConnected ? .green : .orange
        }

        private func statusText(_ terminal: Dieter_V1_Terminal) -> String {
            if terminal.status == "running" { return model.streamConnected ? "Connected" : "Reconnecting" }
            return terminal.hasExitCode ? "Exited \(terminal.exitCode)" : "Exited"
        }
    }

    private struct IOSTerminalAccessoryBar: View {
        let acceptsInput: Bool
        let controlArmed: Bool
        let toggleControl: () -> Void
        let hideKeyboard: () -> Void
        let send: (Data, Bool) -> Void

        var body: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    key("Esc", identifier: "escape") { send(IOSTerminalKeyInput.escape, false) }
                    key("Tab", identifier: "tab") { send(IOSTerminalKeyInput.tab, false) }
                    Button("Ctrl", action: toggleControl)
                        .buttonStyle(IOSTerminalAccessoryKeyStyle(active: controlArmed))
                        .accessibilityLabel(controlArmed ? "Control key armed" : "Control key")
                        .accessibilityHint("Applies Control to the next typed key")
                        .accessibilityIdentifier("ios.terminals.key.control")

                    Menu {
                        ForEach(1...12, id: \.self) { number in
                            Button("F\(number)") {
                                if let data = IOSTerminalKeyInput.function(number) { send(data, false) }
                            }
                        }
                    } label: {
                        Text("F1–12")
                    }
                    .buttonStyle(IOSTerminalAccessoryKeyStyle())
                    .accessibilityIdentifier("ios.terminals.key.function")

                    IOSDirectionalTerminalKey { send(IOSTerminalKeyInput.arrow($0), false) }

                    textKey("/", identifier: "slash") { Data("/".utf8) }
                    textKey(":", identifier: "colon") { Data(":".utf8) }
                    textKey("−", identifier: "minus") { Data("-".utf8) }
                    textKey("|", identifier: "pipe") { Data("|".utf8) }
                    key("Return", systemImage: "return", identifier: "return") {
                        send(IOSTerminalKeyInput.enter, false)
                    }
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
            _ title: String,
            systemImage: String? = nil,
            identifier: String,
            action: @escaping () -> Void
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

        private func textKey(
            _ title: String,
            identifier: String,
            data: @escaping () -> Data
        ) -> some View {
            key(title, identifier: identifier) { send(data(), true) }
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

    private struct IOSDirectionalTerminalKey: View {
        let send: (IOSTerminalDirection) -> Void
        @State private var activeDirection: IOSTerminalDirection?
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
            let direction: IOSTerminalDirection
            if abs(translation.width) > abs(translation.height) {
                direction = translation.width < 0 ? .left : .right
            } else {
                direction = translation.height < 0 ? .up : .down
            }
            guard direction != activeDirection else { return }
            repeatTask?.cancel()
            activeDirection = direction
            send(direction)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            repeatTask = Task { @MainActor in
                try? await DieterTaskSleep.milliseconds(360)
                while !Task.isCancelled {
                    send(direction)
                    try? await DieterTaskSleep.milliseconds(85)
                }
            }
        }

        private func stop() {
            repeatTask?.cancel()
            repeatTask = nil
            activeDirection = nil
        }
    }

    private struct IOSTerminalCreateView: View {
        @Environment(\.dismiss) private var dismiss
        let machineName: String
        let create: (String, String, String) async -> Void
        @State private var name = ""
        @State private var shell = ""
        @State private var directory = "~"
        @State private var creating = false

        var body: some View {
            NavigationStack {
                Form {
                    Section("Destination") {
                        Label(machineName, systemImage: "desktopcomputer")
                        Label("Machine home", systemImage: "house")
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
                        TextField("Starting directory", text: $directory)
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
                        .disabled(creating || directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("ios.terminals.create-confirm")
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .interactiveDismissDisabled(creating)
        }
    }

    struct IOSTerminalsPlaceholderView: View {
        let open: () -> Void

        var body: some View {
            ContentUnavailableView {
                Label("Choose a terminal host", systemImage: "terminal")
            } description: {
                Text("Pick an enrolled machine before opening a persistent shell.")
            } actions: {
                Button("Choose Machine", action: open)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private struct IOSTerminalSurface: UIViewRepresentable {
        let terminalID: String
        let initialColumns: Int
        let initialRows: Int
        let screen: IOSTerminalScreenState
        let acceptsInput: Bool
        let controlArmed: Bool
        let keyboardDismissRevision: Int
        let send: (Data) -> Void
        let consumeControl: () -> Void
        let resize: (Int, Int) -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(send: send, consumeControl: consumeControl, resize: resize)
        }

        func makeUIView(context: Context) -> SwiftTerm.TerminalView {
            let view = SwiftTerm.TerminalView(
                frame: .zero,
                font: .monospacedSystemFont(ofSize: 13, weight: .regular))
            view.nativeForegroundColor = UIColor(white: 0.9, alpha: 1)
            view.nativeBackgroundColor = UIColor(red: 0.035, green: 0.047, blue: 0.055, alpha: 1)
            view.caretColor = UIColor.systemOrange
            view.resize(cols: max(2, initialColumns), rows: max(1, initialRows))
            view.terminalDelegate = context.coordinator
            // Dieter supplies the reference-style SwiftUI key bar above. Keep
            // SwiftTerm's generic accessory from creating a second key row.
            view.inputAccessoryView = nil
            view.accessibilityIdentifier = "ios.terminals.surface"
            view.accessibilityLabel = "Remote terminal"
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
            context.coordinator.send = send
            context.coordinator.resize = resize
            context.coordinator.consumeControl = consumeControl
            context.coordinator.acceptsInput = acceptsInput
            context.coordinator.controlArmed = controlArmed
            if context.coordinator.keyboardDismissRevision != keyboardDismissRevision {
                context.coordinator.keyboardDismissRevision = keyboardDismissRevision
                view.resignFirstResponder()
            }
            context.coordinator.apply(screen, to: view)
        }

        @MainActor
        final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
            var send: (Data) -> Void
            var consumeControl: () -> Void
            var resize: (Int, Int) -> Void
            var acceptsInput = false
            var controlArmed = false
            var keyboardDismissRevision = 0
            private var consumedBytes = 0
            private var resetRevision = -1
            private var resizeTask: Task<Void, Never>?

            init(
                send: @escaping (Data) -> Void,
                consumeControl: @escaping () -> Void,
                resize: @escaping (Int, Int) -> Void
            ) {
                self.send = send
                self.consumeControl = consumeControl
                self.resize = resize
            }

            func apply(_ screen: IOSTerminalScreenState, to view: SwiftTerm.TerminalView) {
                let reset = resetRevision != screen.resetRevision || consumedBytes > screen.byteCount
                if reset {
                    let resetSequence: [UInt8] = [0x1b, 0x63]
                    view.feed(byteArray: resetSequence[...])
                    consumedBytes = 0
                    resetRevision = screen.resetRevision
                }
                if screen.byteCount > consumedBytes {
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
                } else if reset {
                    let empty = [UInt8]()
                    view.feed(byteArray: empty[...])
                }
                view.accessibilityValue = screen.accessibilityText
            }

            func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
                guard acceptsInput else { return }
                let data = Data(data)
                if controlArmed, let modified = IOSTerminalKeyInput.controlModified(data) {
                    controlArmed = false
                    consumeControl()
                    send(modified)
                } else {
                    send(data)
                }
            }

            func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
                resizeTask?.cancel()
                resizeTask = Task { [weak self] in
                    try? await DieterTaskSleep.milliseconds(120)
                    guard !Task.isCancelled, let self else { return }
                    self.resize(newCols, newRows)
                }
            }

            func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
            func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
            func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
            func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
                guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) else { return }
                UIApplication.shared.open(url)
            }
            func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
                if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
            }
            func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
        }
    }
#endif
