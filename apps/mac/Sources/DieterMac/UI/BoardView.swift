import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct BoardView: View {
    @Environment(DieterStore.self) private var store
    var usesTitlebarSpace = false
    var active = true

    var body: some View {
        @Bindable var content = store.conversationContext.content
        let selectedCardID = store.selectedCardID
        // Observe the content model directly so closing the inner workspace
        // restores Kanban in the same update of the outer native split.
        let contentPresented =
            content.splitMode && content.isOpen && content.conversationID == selectedCardID
            && content.endpointID == (content.currentEndpointID(selectedCardID ?? "") ?? "")
        BoardConversationOverlay(
            board: AnyView(
                BoardCanvas().environment(store)
                    .dieterThemeRoot(
                        palette: store.themeSelection.palette, appearance: store.themeSelection.appearance)),
            conversation: AnyView(
                ConversationView(
                    compact: true,
                    surfaceStyle: .inherited,
                    kanbanPresented: store.kanbanPresentedAlongsideConversation,
                    toggleKanban: { store.kanbanPresentedAlongsideConversation.toggle() }
                )
                .background(DieterTheme.surface)
                .environment(store)
                .environment(store.conversationContext)
                .dieterThemeRoot(
                    palette: store.themeSelection.palette, appearance: store.themeSelection.appearance)),
            presented: store.selectedCardID != nil,
            companionPresented: contentPresented,
            boardPresented: store.kanbanPresentedAlongsideConversation,
            active: active
        )
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        // Keep the native split itself in the titlebar region so its divider
        // visually and interactively separates the toolbar navigation above
        // each pane. The split items continue to publish their own safe areas,
        // keeping board and conversation content below the window controls.
        .ignoresSafeArea(
            .container, edges: usesTitlebarSpace && selectedCardID != nil ? .top : []
        )
        .background(DieterTheme.surface)
    }

}

/// Keep board observations separate from conversation presentation and tokens.
struct BoardCanvas: View {
    @Environment(DieterStore.self) private var store
    var usesTitlebarSpace = false
    var active = true

    var body: some View {
        content
            .safeAreaInset(edge: .top) { SharedConflictsButton(keys: store.selectedBoard?.conflictKeys ?? []) }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .background(DieterTheme.surface)
            .ignoresSafeArea(.container, edges: .top)
            .smokeTarget("board.canvas")
    }

    private var content: some View {
        Group {
            switch BoardPresentationState.resolve(
                hasLoadedWorkspace: store.hasLoadedWorkspace,
                selectedBoardID: store.selectedBoardID,
                hasSelectedBoard: store.selectedBoard != nil
            ) {
            case .loading:
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("Loading board…")
                        .font(DieterFont.meta)
                        .foregroundStyle(DieterTheme.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Loading board")
                .accessibilityIdentifier("board.loading")
            case .loaded:
                VStack(spacing: 0) {
                    if let board = store.selectedBoard, board.retired {
                        ContentUnavailableView {
                            Label("Board retired", systemImage: "archivebox")
                        } description: {
                            Text("This empty board and its settings have been preserved.")
                        } actions: {
                            Button("Restore board") { Task { await store.restoreBoard(board.id) } }
                                .accessibilityIdentifier("board.restore")
                                .smokeTarget("board.restore")
                        }
                    } else {
                        BoardHeader()
                        if let board = store.selectedBoard {
                            if board.retirementBlocked {
                                Text(
                                    "This board remains available because it has references or a conflicting retirement change."
                                )
                                .font(DieterFont.meta).padding(8)
                            }
                            KanbanView(board: board)
                        }
                    }
                }
            case .empty:
                ContentUnavailableView {
                    Label("No boards yet", systemImage: "rectangle.split.3x1")
                } description: {
                    Text(
                        "Create a board for \(store.selectedProject?.name ?? "this project") to organize conversations."
                    )
                } actions: {
                    if let projectID = store.selectedProject?.id {
                        Button("Create board") { store.presentNewBoard(projectID: projectID) }
                            .buttonStyle(DieterPrimaryButtonStyle())
                            .accessibilityIdentifier("board.empty-create")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("board.empty")
            }
        }
    }
}
