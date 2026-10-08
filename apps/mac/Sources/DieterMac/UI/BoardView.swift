import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct BoardView: View {
    @Environment(DieterStore.self) private var store
    var active = true

    var body: some View {
        @Bindable var content = store.conversationContext.content
        let selectedCardID = store.selectedCardID
        // Observe the content model directly so closing the inner workspace
        // restores Kanban in the same update of the outer native split.
        let contentPresented =
            content.splitMode && content.isOpen && content.conversationID == selectedCardID
            && content.endpointID == (content.currentEndpointID(selectedCardID ?? "") ?? "")
        VStack(spacing: 0) {
            BoardTopBar()
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
                    .dieterConversationPanel()
                    .padding(.leading, DieterMetrics.panelGap)
                    .padding(.trailing, DieterMetrics.windowInset)
                    .padding(.bottom, DieterMetrics.windowInset)
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
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
    }

}

/// Keep board observations separate from conversation presentation and tokens.
struct BoardCanvas: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
        content
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
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
                    } else if let board = store.selectedBoard {
                        KanbanView(board: board)
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
                            .buttonStyle(DieterBarButtonStyle(prominent: true))
                            .accessibilityIdentifier("board.empty-create")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("board.empty")
            }
        }
    }
}
