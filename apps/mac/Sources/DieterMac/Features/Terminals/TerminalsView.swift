import AppKit
import DieterAPI
import DieterShared
@preconcurrency import SwiftTerm
import SwiftUI

struct TerminalsView: View {
    @Environment(DieterStore.self) private var store
    @Bindable var model: TerminalsModel
    let showAll: @MainActor () async -> Void
    @State private var closeCandidate: TerminalOverviewEntry?
    @State private var renamePresented = false
    @State private var renameValue = ""

    private var selected: Dieter_V1_Terminal? { model.selectedTerminal }

    var body: some View {
        DieterSectionScaffold {
            DieterTitleCapsule(
                title: "Terminals", count: visibleEntries.isEmpty ? nil : visibleEntries.count,
                detail: model.terminalScopeCardID == nil
                    ? store.terminalOverview.terminalOverviewStatus : model.terminalStatus)
        } trailing: {
            if model.terminalScopeCardID != nil {
                Button("All terminals") { Task { await showAll() } }
                    .buttonStyle(DieterBarButtonStyle())
            }
            Button {
                model.createTerminalPresented = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    Text("New terminal")
                }
            }
            .buttonStyle(DieterBarButtonStyle())
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .accessibilityIdentifier("terminals.new").disabled(!model.isLive)
        } content: {
            VStack(spacing: 0) {
                if !visibleEntries.isEmpty, visibleLoading || visibleError != nil {
                    LoadFeedback(
                        title: "Refreshing terminals…", error: visibleError,
                        retry: { Task { await store.loadTerminals() } }, compact: true)
                }
                if !visibleEntries.isEmpty {
                    terminalTabs
                    Rectangle().fill(DieterTheme.hairline).frame(height: 1)
                }

                if visibleLoading && visibleEntries.isEmpty {
                    LoadFeedback(title: "Loading persistent terminals…")
                } else if let error = visibleError, visibleEntries.isEmpty {
                    LoadFeedback(title: "Terminals", error: error, retry: { Task { await store.loadTerminals() } })
                } else if let selected {
                    terminalWorkspace(selected)
                } else {
                    emptyState
                }
            }
        }
        .sheet(isPresented: $model.createTerminalPresented) {
            NewTerminalSheet()
        }
        .confirmationDialog(
            "Close \(closeCandidate?.terminal.name ?? "terminal")?",
            isPresented: Binding(get: { closeCandidate != nil }, set: { if !$0 { closeCandidate = nil } })
        ) {
            if let closeCandidate {
                Button("Close terminal", role: .destructive) {
                    let id = closeCandidate.id
                    self.closeCandidate = nil
                    Task {
                        if model.terminalScopeCardID == nil {
                            await store.closeTerminalOverviewEntry(id)
                        } else {
                            await model.closeTerminal(id: closeCandidate.terminal.id)
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) { closeCandidate = nil }
        } message: {
            Text(
                closeCandidate.map { $0.row.closeMessage } ?? "")
        }
        .alert("Rename terminal", isPresented: $renamePresented) {
            TextField("Name", text: $renameValue)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                guard let id = model.selectedTerminalID else { return }
                Task { await model.renameTerminal(id: id, name: renameValue) }
            }
        } message: {
            Text("Use a short name that describes what is running in this session.")
        }
        .task { await store.loadTerminals() }
        .alert(
            "Terminal",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var visibleEntries: [TerminalOverviewEntry] {
        if model.terminalScopeCardID == nil { return store.terminalOverview.terminalOverviewEntries }
        return model.terminals.map {
            TerminalOverviewEntry(
                machineID: model.target.endpointID, machineName: model.machineName, terminal: $0, row: model.row($0))
        }
    }

    private var visibleLoading: Bool {
        model.terminalScopeCardID == nil ? store.terminalOverview.terminalOverviewLoading : model.terminalLoading
    }

    private var visibleError: String? {
        model.terminalScopeCardID == nil ? store.terminalOverview.terminalOverviewError : model.terminalError
    }

    private var terminalTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                DieterSegmentTrack {
                    ForEach(visibleEntries) { entry in
                        TerminalTab(
                            terminal: entry.terminal,
                            row: entry.row,
                            machineID: entry.machineID,
                            machineName: entry.machineName,
                            selected: entry.id == selectedEntryID,
                            select: {
                                if model.terminalScopeCardID == nil {
                                    Task { await store.terminalOverview.selectTerminalOverviewEntry(entry.id) }
                                } else {
                                    model.selectTerminal(entry.terminal.id)
                                }
                            },
                            close: { closeCandidate = entry }
                        )
                    }
                }
                Button {
                    model.createTerminalPresented = true
                } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 26))
                .help("New terminal")
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 44)
    }

    private var selectedEntryID: String? {
        if model.terminalScopeCardID == nil { return store.terminalOverview.selectedTerminalOverviewID }
        guard let id = model.selectedTerminalID else { return nil }
        return TerminalOverviewEntry.id(machineID: model.target.endpointID, terminalID: id)
    }

    private func terminalWorkspace(_ terminal: Dieter_V1_Terminal) -> some View {
        VStack(spacing: 0) {
            RemoteTerminalSurface(
                terminalID: terminal.id,
                initialColumns: Int(terminal.columns),
                initialRows: Int(terminal.rows),
                screen: model.terminalScreens[terminal.id] ?? TerminalScreenState(),
                acceptsInput: model.row(terminal).acceptsInput,
                send: { model.sendTerminalInput(id: terminal.id, data: $0) },
                resize: { columns, rows in
                    Task { await model.resizeTerminal(id: terminal.id, columns: columns, rows: rows) }
                }
            )
            .id(terminal.id)
            .background(DieterTheme.terminalBackground)

            Divider().overlay(DieterTheme.border)
            HStack(spacing: 8) {
                Circle()
                    .fill(model.row(terminal).tone.color)
                    .frame(width: 6, height: 6)
                Text(model.row(terminal).status)
                    .foregroundStyle(DieterTheme.subtle)
                if !model.machineName.isEmpty {
                    Text(model.machineName).foregroundStyle(DieterTheme.tertiary).lineLimit(1)
                }
                Text(SharedRules.shared.compactPath(path: terminal.workingDirectory))
                    .foregroundStyle(DieterTheme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(terminal.shell)
                Text("·")
                Text("\(terminal.columns)×\(terminal.rows)")
                Text("·")
                Text("UTF-8")
                Menu {
                    Button("Rename…", systemImage: "pencil") {
                        renameValue = terminal.name
                        renamePresented = true
                    }
                    Divider()
                    Button("Close terminal…", systemImage: "xmark", role: .destructive) {
                        closeCandidate =
                            visibleEntries.first(where: {
                                $0.machineID == model.target.endpointID && $0.terminal.id == terminal.id
                            })
                            ?? TerminalOverviewEntry(
                                machineID: model.target.endpointID, machineName: model.machineName, terminal: terminal)
                    }
                } label: {
                    DieterMenuLabel(symbol: "ellipsis", size: 24)
                }
                .dieterMenuChrome(.circle)
                .help("Terminal actions")
                .accessibilityLabel("Terminal actions")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(DieterTheme.tertiary)
            .padding(.horizontal, 12)
            .frame(height: 28)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(DieterTheme.tileHover)
                    .frame(width: 54, height: 54)
                Image(systemName: "terminal")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(DieterTheme.shell)
            }
            Text(model.terminalScopeCardID == nil ? "No terminals" : "No terminals in this conversation")
                .font(.system(size: 16, weight: .semibold))
            Text(
                model.terminalScopeCardID == nil
                    ? "Open a persistent terminal in a project or a machine home. Sessions from every online machine appear here."
                    : "Sessions run in this conversation workspace and remain available when this app disconnects or closes."
            )
            .font(DieterFont.meta)
            .foregroundStyle(DieterTheme.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 390)
            Button("Open a terminal") { model.createTerminalPresented = true }
                .buttonStyle(DieterBarButtonStyle(prominent: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct TerminalTab: View {
    let terminal: Dieter_V1_Terminal
    let row: ClientTerminalRow
    let machineID: String
    let machineName: String
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var closeHovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 7) {
                Circle()
                    .fill(row.running ? DieterTheme.running : DieterTheme.tertiary)
                    .frame(width: 6, height: 6)
                Text(terminal.name)
                Text(machineName)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(DieterTheme.subtle)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(DieterTheme.tileHover, in: Capsule())
                    .accessibilityIdentifier("terminal.node.\(machineID)")
                    .smokeTarget("terminal.node.\(machineID).\(terminal.id)")
                if !row.running {
                    Text(row.status)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(DieterTheme.tertiary)
                }
            }
            .frame(minWidth: 120, maxWidth: 210, alignment: .leading)
            // Room for the close button, which sits inside the segment's trailing edge.
            .padding(.trailing, 14)
        }
        .buttonStyle(DieterSegmentStyle(selected: selected))
        .accessibilityLabel("\(terminal.name), \(machineName)")
        .accessibilityIdentifier("terminal.select.\(machineID).\(terminal.id)")
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
            .help("Close terminal")
            .padding(.trailing, 7)
        }
        .contextMenu {
            Button("Close terminal…", role: .destructive, action: close)
        }
    }
}

private struct NewTerminalSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var checkoutID = ""
    private var projectID: String { selectedDestination?.project.id ?? "" }
    @State private var machineID = ""
    @State private var name = ""
    @State private var shell = "zsh"
    @State private var workingDirectory = ""
    @State private var creating = false
    @FocusState private var focusedField: Field?

    private enum Field { case name, workingDirectory }

    private var availableProjects: [Dieter_V1_Project] { store.projects.filter { !$0.archived } }
    private var destinationGroups: [ProjectDestinationGroup] {
        store.projectDestinationGroups(projects: availableProjects)
    }
    private var selectedDestination: ProjectDestination? {
        destinationGroups.flatMap(\.destinations).first { $0.checkoutID == checkoutID }
    }
    private var selectedProject: Dieter_V1_Project? { selectedDestination?.project }
    private var machines: [MachineEndpoint] { store.machines }
    private var selectedMachine: MachineEndpoint? {
        if let selectedDestination {
            return machines.first { $0.id == selectedDestination.machineID }
        }
        return machines.first { $0.id == machineID }
    }
    private var machineHome: Bool { projectID.isEmpty }
    private var destinationDetail: String {
        if machineHome {
            return selectedMachine.map { "\(SharedRules.shared.machinePresence(online: $0.online)) · Home directory" }
                ?? ""
        }
        return selectedDestination.map { "\($0.machineName) · \($0.detail)" } ?? ""
    }
    private var canCreate: Bool {
        !creating && selectedMachine.map(store.machineIsAvailable) == true
            && (machineHome || !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(DieterTheme.selection)
                        .frame(width: 40, height: 40)
                    Image(systemName: "terminal")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DieterTheme.shell)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("New terminal")
                        .font(.system(size: 19, weight: .semibold))
                    Text(
                        selectedMachine.map { "Start a persistent shell on \($0.name)" }
                            ?? "Choose where to start a persistent shell"
                    )
                    .font(DieterFont.meta)
                    .foregroundStyle(DieterTheme.tertiary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 28))
                .help("Close")
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider().overlay(DieterTheme.border)

            VStack(alignment: .leading, spacing: 15) {
                terminalFieldLabel("Project")
                HStack(spacing: 10) {
                    Image(systemName: machineHome ? "house" : "folder")
                        .foregroundStyle(DieterTheme.shell)
                    Picker("Project & checkout", selection: $checkoutID) {
                        Text("Machine home (no project)").tag("")
                        ForEach(destinationGroups) { group in
                            Section(group.title) {
                                ForEach(group.destinations) { destination in
                                    Text(
                                        "\(destination.project.name) · \(destination.checkout?.name ?? destination.checkoutID)"
                                    ).tag(destination.checkoutID)
                                }
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("new-terminal.project")
                    .smokeTarget("new-terminal.project")
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 44)
                .dieterInset()

                if machineHome {
                    terminalFieldLabel("Machine")
                    HStack(spacing: 10) {
                        Image(systemName: "desktopcomputer")
                            .foregroundStyle(DieterTheme.shell)
                        Picker("Machine", selection: $machineID) {
                            ForEach(machines, id: \.id) { machine in
                                Text("\(machine.name) · \(SharedRules.shared.machinePresence(online: machine.online))")
                                    .tag(machine.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("new-terminal.machine")
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .dieterInset()
                } else if !destinationDetail.isEmpty {
                    HStack(spacing: 9) {
                        Image(systemName: "desktopcomputer")
                        Text(destinationDetail)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                    .foregroundStyle(DieterTheme.tertiary)
                    .padding(.horizontal, 12)
                }

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        terminalFieldLabel("Name", detail: "Optional")
                        TextField(selectedProject?.name ?? selectedMachine?.name ?? "Terminal name", text: $name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .focused($focusedField, equals: .name)
                            .padding(.horizontal, 11)
                            .frame(height: 38)
                            .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(fieldBorder(focusedField == .name))
                            .accessibilityIdentifier("new-terminal.name")
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        terminalFieldLabel("Shell")
                        DieterSegmentedPicker(
                            "Shell", selection: $shell, options: ["zsh", "bash", "fish"], fillsWidth: true,
                            optionTitle: { $0 }
                        )
                        .frame(height: 38)
                        .accessibilityIdentifier("new-terminal.shell")
                    }
                    .frame(width: 190)
                }

                VStack(alignment: .leading, spacing: 7) {
                    terminalFieldLabel("Starting directory")
                    HStack(spacing: 9) {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.system(size: 11))
                            .foregroundStyle(DieterTheme.tertiary)
                        TextField(machineHome ? "Home directory" : "Project directory", text: $workingDirectory)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                            .focused($focusedField, equals: .workingDirectory)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 38)
                    .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(fieldBorder(focusedField == .workingDirectory))
                    .accessibilityIdentifier("new-terminal.directory")
                }

                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DieterTheme.shell)
                    Text(
                        machineHome
                            ? "The shell stays inside this machine's home directory. It remains available across app and daemon reconnects."
                            : "The shell stays inside this project. It remains available across app and daemon reconnects."
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(DieterTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    DieterTheme.shellDeep.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(DieterTheme.shellDeep.opacity(0.22)))
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Divider().overlay(DieterTheme.border)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(DieterBarButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button {
                    creating = true
                    Task {
                        await store.createTerminal(
                            projectID: projectID, checkoutID: checkoutID,
                            machineID: selectedMachine?.id,
                            machineHome: machineHome,
                            name: name,
                            shell: shell,
                            workingDirectory: workingDirectory
                        )
                        creating = false
                    }
                } label: {
                    HStack(spacing: 7) {
                        if creating {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "terminal")
                        }
                        Text("Open terminal")
                    }
                }
                .buttonStyle(DieterBarButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
                .accessibilityIdentifier("new-terminal.create")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .background(DieterTheme.background)
        .onAppear {
            let allDestinations = destinationGroups.flatMap(\.destinations)
            let preferred =
                allDestinations.first(where: {
                    $0.project.id == store.selectedProjectID && $0.machineOnline
                }) ?? allDestinations.first(where: \.machineOnline)
            if let preferred {
                checkoutID = preferred.checkoutID
                machineID = preferred.machineID
                workingDirectory = preferred.checkout?.path.isEmpty == false ? preferred.checkout!.path : "."
            } else {
                machineID =
                    store.terminalOverview.terminalOverviewPreferredMachineID
                    ?? machines.first(where: { store.machineIsAvailable($0) })?.id
                    ?? ""
                checkoutID = ""
                workingDirectory = "~"
            }
        }
        .onChange(of: checkoutID) { _, value in
            guard !value.isEmpty else {
                workingDirectory = "~"
                return
            }
            guard let destination = destinationGroups.flatMap(\.destinations).first(where: { $0.checkoutID == value })
            else { return }
            machineID = destination.machineID
            workingDirectory = destination.checkout?.path.isEmpty == false ? destination.checkout!.path : "."
        }
    }

    private func terminalFieldLabel(_ title: String, detail: String? = nil) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DieterTheme.subtle)
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(DieterTheme.tertiary)
            }
        }
    }

    private func fieldBorder(_ focused: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(
                focused ? DieterTheme.shellDeep.opacity(0.85) : DieterTheme.strongBorder, lineWidth: focused ? 1.5 : 1)
    }
}

struct RemoteTerminalSurface: NSViewRepresentable {
    let terminalID: String
    let initialColumns: Int
    let initialRows: Int
    let screen: TerminalScreenState
    let acceptsInput: Bool
    let send: (Data) -> Void
    let resize: (Int, Int) -> Void
    var active = true

    func makeCoordinator() -> Coordinator {
        Coordinator(terminalID: terminalID, send: send, resize: resize)
    }

    func makeNSView(context: Context) -> RemoteTerminalView {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = RemoteTerminalView(frame: .zero, font: font)
        // NSViewRepresentable creates AppKit views before SwiftUI assigns their
        // real frame. Replay at the PTY's persisted geometry instead of
        // SwiftTerm's two-column minimum so reconnect output cannot be
        // permanently reflowed from a zero-sized bootstrap frame.
        view.prepareForReplay(columns: initialColumns, rows: initialRows)
        view.acceptsRemoteInput = acceptsInput
        context.coordinator.active = active
        context.coordinator.acceptsInput = acceptsInput
        view.terminalDelegate = context.coordinator
        view.applyPalette(
            foreground: DieterTheme.terminalForegroundColor,
            background: DieterTheme.terminalBackgroundColor,
            caret: DieterTheme.terminalCaretColor)
        context.coordinator.apply(screen, to: view)
        context.coordinator.active = active
        context.coordinator.acceptsInput = acceptsInput
        DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
            guard let view, coordinator?.active == true, view.window?.isKeyWindow == true,
                !view.isHiddenOrHasHiddenAncestor, view.bounds.width > 0, view.bounds.height > 0
            else { return }
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ view: RemoteTerminalView, context: Context) {
        context.coordinator.terminalID = terminalID
        context.coordinator.send = send
        context.coordinator.resize = resize
        context.coordinator.acceptsInput = acceptsInput
        context.coordinator.active = active
        view.acceptsRemoteInput = acceptsInput
        view.applyPalette(
            foreground: DieterTheme.terminalForegroundColor,
            background: DieterTheme.terminalBackgroundColor,
            caret: DieterTheme.terminalCaretColor)
        context.coordinator.apply(screen, to: view)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        var terminalID: String
        var send: (Data) -> Void
        var resize: (Int, Int) -> Void
        var acceptsInput = true
        var active = true
        private var resizeWorkItem: DispatchWorkItem?
        private let screenRenderer = RemoteTerminalScreenRenderer()

        init(terminalID: String, send: @escaping (Data) -> Void, resize: @escaping (Int, Int) -> Void) {
            self.terminalID = terminalID
            self.send = send
            self.resize = resize
        }

        @MainActor
        func apply(_ screen: TerminalScreenState, to view: SwiftTerm.TerminalView) {
            screenRenderer.apply(screen, to: view)
        }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            guard active, acceptsInput else { return }
            send(Data(data))
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            resizeWorkItem?.cancel()
            guard active else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.active else { return }
                self.resize(newCols, newRows)
            }
            resizeWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}

/// Keeps SwiftTerm's emulator grid aligned with the AppKit view under Auto
/// Layout. AppKit can resize an NSView through `setFrameSize`, which otherwise
/// stretches the surface without resizing the terminal buffer.
@MainActor
final class RemoteTerminalView: SwiftTerm.TerminalView {
    private final class MonitorBox: @unchecked Sendable {
        var token: Any?

        func remove() {
            if let token { NSEvent.removeMonitor(token) }
            token = nil
        }
    }

    var acceptsRemoteInput = true
    private(set) var paletteMutationCount = 0
    private var selectionAnchorEvent: NSEvent?
    private let editCommandMonitor = MonitorBox()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        editCommandMonitor.remove()
        guard window != nil else { return }
        editCommandMonitor.token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.window?.firstResponder === self else { return event }
            return self.performStandardEditCommand(for: event) ? nil : event
        }
    }

    deinit { editCommandMonitor.remove() }

    func applyPalette(foreground: NSColor, background: NSColor, caret: NSColor) {
        if nativeForegroundColor != foreground {
            nativeForegroundColor = foreground
            paletteMutationCount += 1
        }
        if nativeBackgroundColor != background {
            // SwiftTerm's setter also updates its backing layer. Reassigning it
            // for every output frame needlessly propagates through the emulator.
            nativeBackgroundColor = background
            paletteMutationCount += 1
        }
        if caretColor != caret {
            caretColor = caret
            paletteMutationCount += 1
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        synchronizeGridToBounds()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        selectionAnchorEvent = event.clickCount == 1 && usesTextSelection(for: event) ? event : nil
        withTextSelectionOverride(for: event) {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        withTextSelectionOverride(for: event) {
            // SwiftTerm starts a character selection at the first drag event,
            // not at mouse-down. A short native drag can contain only one drag
            // event and would therefore produce an empty selection. Seed that
            // selection from the original click before extending it.
            if let anchor = selectionAnchorEvent {
                super.mouseDragged(with: anchor)
                selectionAnchorEvent = nil
            }
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        selectionAnchorEvent = nil
        withTextSelectionOverride(for: event) {
            super.mouseUp(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        performStandardEditCommand(for: event) || super.performKeyEquivalent(with: event)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) {
            return acceptsRemoteInput && NSPasteboard.general.string(forType: .string) != nil
        }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any) {
        guard acceptsRemoteInput else { return }
        super.paste(sender)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let menu = NSMenu(title: "Terminal")
        menu.autoenablesItems = false
        menu.addItem(editMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "c"))
        menu.addItem(editMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: "v"))
        menu.addItem(.separator())
        menu.addItem(editMenuItem(title: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "a"))
        return menu
    }

    func prepareForReplay(columns: Int, rows: Int) {
        terminal.resize(cols: max(2, columns), rows: max(1, rows))
    }

    private func usesTextSelection(for event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.shift) { return true }
        guard allowMouseReporting else { return true }
        switch terminal.mouseMode {
        case .off: return true
        default: return false
        }
    }

    private func withTextSelectionOverride(for event: NSEvent, _ body: () -> Void) {
        guard event.modifierFlags.contains(.shift), allowMouseReporting else {
            body()
            return
        }
        allowMouseReporting = false
        body()
        allowMouseReporting = true
    }

    private func standardEditModifiers(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.intersection([.command, .option, .control, .shift]) == .command
    }

    private func performStandardEditCommand(for event: NSEvent) -> Bool {
        guard event.type == .keyDown, standardEditModifiers(event.modifierFlags),
            let key = event.charactersIgnoringModifiers?.lowercased()
        else { return false }

        switch key {
        case "c": copy(self)
        case "v": paste(self)
        case "a": selectAll(nil)
        default: return false
        }
        return true
    }

    private func editMenuItem(title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = .command
        item.target = self
        item.isEnabled = validateUserInterfaceItem(item)
        return item
    }

    private func synchronizeGridToBounds() {
        guard terminal != nil, bounds.width > 0, bounds.height > 0 else { return }
        let cellSize = caretFrame.size
        guard cellSize.width > 0, cellSize.height > 0 else { return }

        // SwiftTerm reserves a legacy scroller beside the terminal cells. Its
        // public optimal-frame calculation lets us recover that inset without
        // reaching into the dependency's private view state.
        let optimalWidth = getOptimalFrameSize().width
        let cellsWidth = cellSize.width * CGFloat(terminal.cols)
        let scrollerWidth = max(0, optimalWidth - cellsWidth)
        let columns = max(2, Int((bounds.width - scrollerWidth) / cellSize.width))
        let rows = max(1, Int(bounds.height / cellSize.height))
        guard columns != terminal.cols || rows != terminal.rows else { return }

        terminal.resize(cols: columns, rows: rows)
        let empty = [UInt8]()
        feed(byteArray: empty[...])
        terminalDelegate?.sizeChanged(source: self, newCols: columns, newRows: rows)
    }
}

/// Applies replayable daemon output through SwiftTerm's view-level feed path.
///
/// Feeding `Terminal` directly mutates its buffer but skips the view work that
/// advances the visible caret, redraws changed rows, clears stale selections,
/// and follows the live viewport. Keep the replay cursor here so resets and
/// bounded-buffer truncation also perform a coherent full-screen redraw.
@MainActor
final class RemoteTerminalScreenRenderer {
    private var consumedBytes = 0
    private var resetRevision = -1

    func apply(_ screen: TerminalScreenState, to view: SwiftTerm.TerminalView) {
        let needsReset = resetRevision != screen.resetRevision || consumedBytes > screen.byteCount
        if needsReset {
            view.terminal.resetToInitialState()
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
        } else if needsReset {
            // The reset dirties the whole terminal even when the replay is empty.
            // An empty view-level feed schedules SwiftTerm's caret and display pass.
            let empty = [UInt8]()
            view.feed(byteArray: empty[...])
        }
    }
}
