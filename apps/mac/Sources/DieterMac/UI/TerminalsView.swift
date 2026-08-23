import AppKit
import DieterAPI
@preconcurrency import SwiftTerm
import SwiftUI

struct TerminalsView: View {
    @Environment(DieterStore.self) private var store
    @State private var closeCandidate: Dieter_V1_Terminal?
    @State private var renamePresented = false
    @State private var renameValue = ""

    private var selected: Dieter_V1_Terminal? { store.selectedTerminal }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            FluidPaneChrome {
                HStack(spacing: 12) {
                    PaneTitleBlock(
                        title: "Terminals",
                        subtitle: "\(store.terminals.count) persistent \(store.terminals.count == 1 ? "session" : "sessions") · \(store.endpoint.name)",
                        prominent: true
                    )
                    Spacer()
                    Button {
                        store.createTerminalPresented = true
                    } label: {
                        Label("New terminal", systemImage: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(DieterTheme.shellDeep, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .accessibilityIdentifier("terminals.new")
                }
            }

            Divider().overlay(DieterTheme.border)

            if !store.terminals.isEmpty {
                terminalTabs
                Divider().overlay(DieterTheme.border)
            }

            if store.terminalLoading && store.terminals.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading persistent terminals…")
                        .font(DieterFont.meta)
                        .foregroundStyle(DieterTheme.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let selected {
                terminalWorkspace(selected)
            } else {
                emptyState
            }
        }
        .background(DieterTheme.background)
        .sheet(isPresented: $store.createTerminalPresented) {
            NewTerminalSheet().environment(store)
        }
        .confirmationDialog(
            "Close \(closeCandidate?.name ?? "terminal")?",
            isPresented: Binding(get: { closeCandidate != nil }, set: { if !$0 { closeCandidate = nil } })
        ) {
            if let closeCandidate {
                Button("Close terminal", role: .destructive) {
                    let id = closeCandidate.id
                    self.closeCandidate = nil
                    Task { await store.closeTerminal(id: id) }
                }
            }
            Button("Cancel", role: .cancel) { closeCandidate = nil }
        } message: {
            Text(closeCandidate?.status == "running"
                ? "This explicitly ends the daemon-owned shell and its running command. Closing the Mac app does not."
                : "This removes the finished session and its scrollback.")
        }
        .alert("Rename terminal", isPresented: $renamePresented) {
            TextField("Name", text: $renameValue)
            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                guard let id = store.selectedTerminalID else { return }
                Task { await store.renameTerminal(id: id, name: renameValue) }
            }
        } message: {
            Text("Use a short name that describes what is running in this session.")
        }
        .task {
            if store.terminals.isEmpty { await store.loadTerminals() }
        }
    }

    private var terminalTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(store.terminals, id: \.id) { terminal in
                    TerminalTab(
                        terminal: terminal,
                        selected: terminal.id == store.selectedTerminalID,
                        select: { store.selectTerminal(terminal.id) },
                        close: { closeCandidate = terminal }
                    )
                }
                Button { store.createTerminalPresented = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DieterTheme.tertiary)
                .help("New terminal")
            }
        }
        .frame(height: 38)
        .background(DieterTheme.sidebar)
    }

    private func terminalWorkspace(_ terminal: Dieter_V1_Terminal) -> some View {
        VStack(spacing: 0) {
            RemoteTerminalSurface(
                terminalID: terminal.id,
                screen: store.terminalScreens[terminal.id] ?? TerminalScreenState(),
                acceptsInput: terminal.status == "running" && store.terminalStreamConnected,
                send: { store.sendTerminalInput(id: terminal.id, data: $0) },
                resize: { columns, rows in
                    Task { await store.resizeTerminal(id: terminal.id, columns: columns, rows: rows) }
                }
            )
            .id(terminal.id)
            .background(Color(nsColor: NSColor(rgb: 0x0A0A0E)))

            Divider().overlay(DieterTheme.border)
            HStack(spacing: 8) {
                Circle()
                    .fill(terminalStatusColor(terminal))
                    .frame(width: 6, height: 6)
                Text(terminalStatusText(terminal))
                    .foregroundStyle(DieterTheme.subtle)
                Text(abbreviatedPath(terminal.workingDirectory))
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
                        closeCandidate = terminal
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 22, height: 18)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(DieterTheme.tertiary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(DieterTheme.sidebar)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(DieterTheme.selection)
                    .frame(width: 54, height: 54)
                Image(systemName: "terminal")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(DieterTheme.shell)
            }
            Text("No terminals on \(store.endpoint.name)")
                .font(.system(size: 16, weight: .semibold))
            Text("Sessions run on the daemon and remain available when this app disconnects or closes.")
                .font(DieterFont.meta)
                .foregroundStyle(DieterTheme.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 390)
            Button("Open a terminal") { store.createTerminalPresented = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func terminalStatusColor(_ terminal: Dieter_V1_Terminal) -> SwiftUI.Color {
        if terminal.status != "running" { return terminal.hasExitCode && terminal.exitCode == 0 ? DieterTheme.tertiary : DieterTheme.coral }
        return store.terminalStreamConnected ? DieterTheme.eyes : DieterTheme.amber
    }

    private func terminalStatusText(_ terminal: Dieter_V1_Terminal) -> String {
        if terminal.status == "running" {
            return store.terminalStreamConnected ? store.endpoint.name : "Reconnecting"
        }
        return terminal.hasExitCode ? "Exited \(terminal.exitCode)" : "Exited"
    }

    private func abbreviatedPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

private struct TerminalTab: View {
    let terminal: Dieter_V1_Terminal
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Button(action: select) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(terminal.status == "running" ? DieterTheme.eyes : DieterTheme.tertiary)
                        .frame(width: 5, height: 5)
                    Text(terminal.name)
                        .font(.system(size: 11, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                    if terminal.status != "running" {
                        Text("exited")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(DieterTheme.tertiary)
                    }
                }
                .frame(minWidth: 120, maxWidth: 210, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .background(hovering ? DieterTheme.raised : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DieterTheme.tertiary)
            .help("Close terminal")
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
        .contextMenu {
            Button("Close terminal…", role: .destructive, action: close)
        }
    }
}

private struct NewTerminalSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var projectID = ""
    @State private var name = ""
    @State private var shell = "zsh"
    @State private var workingDirectory = ""
    @State private var creating = false

    private var availableProjects: [Dieter_V1_Project] { store.projects.filter { !$0.archived } }
    private var selectedProject: Dieter_V1_Project? { availableProjects.first { $0.id == projectID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(DieterTheme.selection)
                        .frame(width: 34, height: 34)
                    Image(systemName: "terminal")
                        .foregroundStyle(DieterTheme.shell)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("New terminal").font(.system(size: 16, weight: .semibold))
                    Text("Runs persistently on \(store.endpoint.name)")
                        .font(DieterFont.meta).foregroundStyle(DieterTheme.tertiary)
                }
                Spacer()
            }
            .padding(18)

            Divider().overlay(DieterTheme.border)

            Form {
                Picker("Project", selection: $projectID) {
                    ForEach(availableProjects, id: \.id) { project in
                        Text(project.name).tag(project.id)
                    }
                }
                .onChange(of: projectID) { _, id in
                    if let project = availableProjects.first(where: { $0.id == id }) {
                        workingDirectory = project.path
                    }
                }

                TextField("Name", text: $name, prompt: Text(selectedProject?.name ?? "Optional"))
                TextField("Start in", text: $workingDirectory)
                    .font(.system(size: 11, design: .monospaced))

                Picker("Shell", selection: $shell) {
                    Text("zsh").tag("zsh")
                    Text("bash").tag("bash")
                    Text("fish").tag("fish")
                }
                .pickerStyle(.segmented)

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(DieterTheme.eyes)
                    Text("The working directory is restricted to the registered project. Output is replayed from a bounded daemon buffer after reconnecting.")
                        .font(.system(size: 10))
                        .foregroundStyle(DieterTheme.tertiary)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 10)

            Divider().overlay(DieterTheme.border)
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if creating { ProgressView().controlSize(.small) }
                Button("Open terminal") {
                    creating = true
                    Task {
                        await store.createTerminal(
                            projectID: projectID,
                            name: name,
                            shell: shell,
                            workingDirectory: workingDirectory
                        )
                        creating = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(projectID.isEmpty || workingDirectory.isEmpty || creating)
            }
            .padding(16)
        }
        .frame(width: 520, height: 430)
        .background(DieterTheme.surface)
        .onAppear {
            projectID = store.selectedProjectID.isEmpty ? (availableProjects.first?.id ?? "") : store.selectedProjectID
            workingDirectory = availableProjects.first(where: { $0.id == projectID })?.path ?? ""
        }
    }
}

private struct RemoteTerminalSurface: NSViewRepresentable {
    let terminalID: String
    let screen: TerminalScreenState
    let acceptsInput: Bool
    let send: (Data) -> Void
    let resize: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(terminalID: terminalID, send: send, resize: resize)
    }

    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = SwiftTerm.TerminalView(frame: .zero, font: font)
        view.terminalDelegate = context.coordinator
        view.nativeForegroundColor = NSColor(rgb: 0xE8E8ED)
        view.nativeBackgroundColor = NSColor(rgb: 0x0A0A0E)
        view.caretColor = NSColor(rgb: 0x5EEAD4)
        view.layer?.backgroundColor = NSColor(rgb: 0x0A0A0E).cgColor
        context.coordinator.apply(screen, to: view)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: SwiftTerm.TerminalView, context: Context) {
        context.coordinator.terminalID = terminalID
        context.coordinator.send = send
        context.coordinator.resize = resize
        context.coordinator.acceptsInput = acceptsInput
        context.coordinator.apply(screen, to: view)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        var terminalID: String
        var send: (Data) -> Void
        var resize: (Int, Int) -> Void
        var acceptsInput = true
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
            guard acceptsInput else { return }
            send(Data(data))
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            resizeWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.resize(newCols, newRows) }
            resizeWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) { }
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) { }
        func scrolled(source: SwiftTerm.TerminalView, position: Double) { }
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(content, forType: .string)
        }
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) { }
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
        let needsReset = resetRevision != screen.resetRevision || consumedBytes > screen.data.count
        if needsReset {
            view.terminal.resetToInitialState()
            consumedBytes = 0
            resetRevision = screen.resetRevision
        }

        if screen.data.count > consumedBytes {
            let bytes = [UInt8](screen.data[consumedBytes...])
            consumedBytes = screen.data.count
            view.feed(byteArray: bytes[...])
        } else if needsReset {
            // The reset dirties the whole terminal even when the replay is empty.
            // An empty view-level feed schedules SwiftTerm's caret and display pass.
            let empty = [UInt8]()
            view.feed(byteArray: empty[...])
        }
    }
}

private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255,
            alpha: 1
        )
    }
}
