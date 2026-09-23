import DieterAPI
import SwiftUI

/// Each workspace tab renders one dedicated daemon terminal. Closing the tab
/// only detaches its watch; explicit shell termination stays in the terminals UI.
struct ConversationTerminalPane: View {
    @Bindable var tab: ConversationContentTab
    private var model: TerminalsModel { tab.terminals }
    private var terminal: Dieter_V1_Terminal? {
        guard let terminalID = tab.terminalID else { return nil }
        return model.terminals.first { $0.id == terminalID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.terminalError ?? model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let terminal {
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
                    Label("Terminal unavailable", systemImage: "terminal")
                } description: {
                    Text("Close this tab and open another Terminal tab to start a new session.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: model.active) {
            if model.active { await model.loadTerminals(selecting: tab.terminalID) }
        }
    }
}
