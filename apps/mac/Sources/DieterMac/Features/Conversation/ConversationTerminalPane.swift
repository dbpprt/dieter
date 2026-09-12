import DieterAPI
import SwiftUI

/// The pane owns only the watch. Closing this view never closes a persistent
/// terminal on the daemon; explicit shell termination stays in the terminals UI.
struct ConversationTerminalPane: View {
    @Bindable var tab: ConversationContentTab
    @State private var creating = false
    private var model: TerminalsModel { tab.terminals }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if !model.terminals.isEmpty {
                    Picker(
                        "Terminal session",
                        selection: Binding(
                            get: { model.selectedTerminalID ?? "" },
                            set: { model.selectTerminal($0) })
                    ) {
                        ForEach(model.terminals, id: \.id) { terminal in
                            Text(terminal.name.isEmpty ? "Terminal" : terminal.name).tag(terminal.id)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(maxWidth: 220)
                } else {
                    Text("Terminal").font(.system(size: 12, weight: .medium))
                }
                Spacer(minLength: 6)
                Button {
                    Task { await create() }
                } label: {
                    Label(creating ? "Opening…" : "New terminal", systemImage: "plus")
                }
                .buttonStyle(.borderless).controlSize(.small)
                .disabled(creating || !model.isLive)
                .accessibilityIdentifier("conversation.content.terminal.create")
                .smokeTarget("conversation.content.terminal.create")
            }
            .padding(.horizontal, 12).frame(height: 36)
            Divider()
            if let error = model.terminalError ?? model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let terminal = model.selectedTerminal {
                RemoteTerminalSurface(
                    terminalID: terminal.id,
                    initialColumns: Int(terminal.columns), initialRows: Int(terminal.rows),
                    screen: model.terminalScreens[terminal.id] ?? TerminalScreenState(),
                    acceptsInput: model.active && terminal.status == "running" && model.terminalStreamConnected,
                    send: { model.sendTerminalInput(id: terminal.id, data: $0) },
                    resize: { columns, rows in
                        guard model.active else { return }
                        Task { await model.resizeTerminal(id: terminal.id, columns: columns, rows: rows) }
                    }, active: model.active
                )
                .id(terminal.id)
                .background(DieterTheme.terminalBackground)
                .accessibilityIdentifier("conversation.content.terminal.surface")
                .smokeTarget("conversation.content.terminal.surface")
                HStack(spacing: 6) {
                    Circle().fill(model.terminalStreamConnected ? DieterTheme.eyes : DieterTheme.tertiary)
                        .frame(width: 5, height: 5)
                    Text(terminal.status == "running" ? model.machineName : "Session finished")
                    Text("·")
                    Text(terminal.workingDirectory).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(terminal.shell)
                }
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).frame(height: 26)
            } else if model.terminalLoading {
                LoadFeedback(title: "Loading terminals…")
            } else {
                ContentUnavailableView {
                    Label("Conversation terminal", systemImage: "terminal")
                } description: {
                    Text("Open a shell in this conversation’s workspace. It stays available when you close the tab.")
                } actions: {
                    Button("Open terminal") { Task { await create() } }
                        .disabled(creating || !model.isLive)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: model.active) {
            if model.active { await model.loadTerminals() }
        }
    }

    private func create() async {
        guard !creating else { return }
        creating = true
        defer { creating = false }
        await model.createTerminal(
            projectID: model.target.projectID, name: "Terminal", shell: "", workingDirectory: ".")
    }
}
