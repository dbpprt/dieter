import AppKit
import DieterAPI
import DieterShared
import Foundation
import Observation
import UniformTypeIdentifiers
import UserNotifications

extension DieterStore {
    var selectedProject: Dieter_V1_Project? {
        if let project = projectDirectory[selectedProjectID] { return project }
        if let project = state.projects.first(where: { $0.id == selectedProjectID }) { return project }
        return state.project.id == selectedProjectID ? state.project : nil
    }

    var renameProjectTarget: Dieter_V1_Project? {
        projectDirectory[renameProjectTargetID]
            ?? state.projects.first(where: { $0.id == renameProjectTargetID })
            ?? (state.project.id == renameProjectTargetID ? state.project : nil)
    }

    var projects: [Dieter_V1_Project] { replica.projects }

    /// Every project's cards, for cross-project navigation. `state.cards`
    /// holds only the selected project; the core's workspace feed keeps
    /// `navigationCards` current in the background.
    func synchronizedCardValues() -> [Dieter_V1_Card] {
        var byID: [String: Dieter_V1_Card] = [:]
        for card in navigationCards.values.joined() where !card.id.isEmpty {
            byID[card.id] = card
        }
        for card in chats where !card.id.isEmpty {
            byID[card.id] = card
        }
        // Selected-project state also carries optimistic changes that may not
        // have reached the authoritative projection yet.
        for card in state.cards + state.chats where !card.id.isEmpty {
            byID[card.id] = card
        }
        return Array(byID.values)
    }

    /// The island's rows and counts from the core's activity slice.
    func refreshIslandActivity() {
        let next = DieterIslandActivity(activity)
        if next != islandActivity { islandActivity = next }
    }

    /// The enrolled machines in the core's order, by name.
    var machines: [MachineEndpoint] {
        endpoints.filter { $0.daemonID != nil }
    }

    var gateways: [MachineEndpoint] {
        gatewayOrigins.sorted {
            let lhsPrimary = $0.isPrimaryGateway
            let rhsPrimary = $1.isPrimaryGateway
            if lhsPrimary != rhsPrimary { return lhsPrimary }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var activeGateway: MachineEndpoint {
        gatewayOrigins.first(where: { $0.credentialID == endpoint.credentialID }) ?? endpoint.gatewayEndpoint
    }

    var hasLoadedWorkspace: Bool {
        coreWorkspace.loaded || !projectDirectory.isEmpty
    }

    func isChatUnread(_ card: Dieter_V1_Card) -> Bool {
        SharedRules.shared.isUnread(card: card.rulesData)
    }

    func isPendingCard(_ id: String) -> Bool { pendingCardIDs.contains(id) }
    /// The conversation exists on its machine, not only in this Mac's outbox.
    func isConversationServerBacked(_ id: String) -> Bool {
        SharedRules.shared.isServerBacked(conversationId: id) && !outboxState.pendingCardIds.contains(id)
    }
    func isPendingMessage(_ id: String) -> Bool { pendingMessageIDs.contains(id) }
    func isAcceptedOutboxItem(_ id: String) -> Bool { acceptedOutboxIDs.contains(id) }
    func isFailedOutboxItem(_ id: String) -> Bool { failedOutboxIDs.contains(id) }
    func failedCreationError(_ id: String) -> String? {
        guard outboxState.pendingCardIds.contains(id) else { return nil }
        return outboxState.failures[id]
    }

    var failedOutboxItems: [DieterFailedOutboxItem] {
        outboxState.failedOperations.map { operation in
            DieterFailedOutboxItem(
                id: operation.id, operation: operation.label, targetID: operation.targetID,
                failure: operation.failure,
                createdAt: Date(timeIntervalSince1970: Double(operation.createdAtMillis) / 1_000))
        }
    }

    func replica(forProjectID projectID: String) -> MachineEndpoint? {
        // This selects a replica for shared metadata, never an execution owner.
        if machineIsAvailable(endpoint), phase.isConnected { return endpoint }
        return endpoints.first { $0.daemonID != nil && machineIsAvailable($0) }
    }

    /// What waits in the outbox for `machine`; nil when nothing does.
    func outbox(for machine: MachineEndpoint) -> ClientMachineOutbox? {
        guard let daemonID = machine.daemonID else { return nil }
        return machineOutboxes.first { $0.daemonID == daemonID }
    }

    /// A machine's status line: the core's detail, when it was last seen
    /// where that matters, and what waits in its outbox.
    func machineStatusLine(_ machine: MachineEndpoint, now: Date = Date()) -> String {
        guard let entry = machineEntry(machine) else { return "" }
        return entry.statusLine(now: now) + (outbox(for: machine)?.statusSuffix ?? "")
    }

    var selectedBoard: Dieter_V1_Board? {
        board(id: selectedBoardID) ?? replica.retiredBoards[selectedBoardID]
    }

    var renameBoardTarget: Dieter_V1_Board? {
        board(id: renameBoardTargetID)
    }

    var selectedCard: Dieter_V1_Card? {
        let id = selectedCardID ?? selectedChatID
        return state.cards.first { $0.id == id } ?? state.chats.first { $0.id == id } ?? chats.first { $0.id == id }
    }

    /// Every card the board shows, lane by lane.
    var displayedCards: [Dieter_V1_Card] {
        boardProjection.displayedCards
    }

    /// What `card` shows and offers: the board view's flags while the board
    /// shows it, else the core's rules over the card, e.g. in the Inbox.
    func cardFlags(_ card: Dieter_V1_Card, board: Dieter_V1_Board?) -> ClientBoardCardFlags {
        if let flags = boardCardFlags[card.id] { return flags }
        return ClientBoardCardFlags(
            rules: SharedRules.shared.cardFlags(
                card: card.rulesData, board: board?.rulesData ?? Data(),
                operation: boardState.operations[card.id] ?? "",
                pending: outboxState.pendingCardIds.contains(card.id), failed: outboxState.failures[card.id] != nil))
    }

    func refreshBoardProjection() {
        bindBoardView()
        let next = BoardProjection.resolve(view: boardView, board: selectedBoard, cards: state.cards)
        if next != boardProjection { boardProjection = next }
        if boardCardFlags != next.view.cards { boardCardFlags = next.view.cards }
    }

    func boards(for projectID: String) -> [Dieter_V1_Board] {
        navigationBoards[projectID] ?? (projectID == state.project.id ? state.boards : [])
    }

    func board(id: String) -> Dieter_V1_Board? {
        guard !id.isEmpty else { return nil }
        if let board = state.boards.first(where: { $0.id == id }) { return board }
        return navigationBoards.values.lazy.compactMap { boards in
            boards.first(where: { $0.id == id })
        }.first
    }
}
