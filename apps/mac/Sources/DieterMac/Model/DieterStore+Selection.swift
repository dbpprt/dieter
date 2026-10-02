import DieterAPI
import Foundation

extension DieterStore {
    /// Publishes the selected project's slice of the replica as `state`.
    func updateSelectedState(base: Dieter_V1_State? = nil) {
        if selectedProjectID.isEmpty || projectDirectory[selectedProjectID] == nil {
            selectedProjectID = preferredInitialProjectID()
        }
        var selected = base ?? state
        selected.project = projectDirectory[selectedProjectID] ?? Dieter_V1_Project()
        selected.projects = projects
        selected.boards = navigationBoards[selectedProjectID] ?? []
        selected.cards = navigationCards[selectedProjectID] ?? []
        selected.chats = chats.filter { $0.projectID == selectedProjectID }
        if state != selected { state = selected }
        if selectedBoardID.isEmpty
            || (!selected.boards.contains(where: { $0.id == selectedBoardID })
                && replica.retiredBoards[selectedBoardID]?.projectID != selectedProjectID)
        {
            selectedBoardID = selected.boards.first?.id ?? ""
        }
    }

    /// The sidebar's first project, else the first listed one.
    private func preferredInitialProjectID() -> String {
        let visibleIDs = Set(projects.filter { !$0.archived }.map(\.id))
        return navigation.projects.order.first(where: visibleIDs.contains)
            ?? projects.first { !$0.archived }?.id
            ?? projects.first?.id
            ?? ""
    }

    /// The core's feed keeps the workspace live; a manual refresh reconnects
    /// when offline and rereads the attached machine's agents and the open
    /// conversation otherwise.
    func refreshState() async {
        stateRefreshCount &+= 1
        guard phase.isConnected else {
            await connect()
            return
        }
        if let daemonID = endpoint.daemonID {
            await perform {
                $0.ensureMetadata = .with {
                    $0.daemonID = daemonID
                    $0.refresh = true
                }
            }
        }
        if let cardID = selectedCardID ?? selectedChatID, isConversationServerBacked(cardID) {
            await perform { $0.refreshConversation = .with { $0.cardID = cardID } }
        }
    }
}
