import AppKit
import DieterAPI
import DieterClientAPI
import DieterCore
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
    /// holds only the selected project; every machine's stream keeps
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

    /// The card `synchronizedCardValues()` holds for `id`, found without
    /// collecting every project's cards.
    func synchronizedCard(id: String) -> Dieter_V1_Card? {
        guard !id.isEmpty else { return nil }
        if let card = state.cards.first(where: { $0.id == id }) ?? state.chats.first(where: { $0.id == id })
            ?? chats.first(where: { $0.id == id })
        {
            return card
        }
        return navigationCards.values.lazy.compactMap { cards in cards.first { $0.id == id } }.first
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

    var hasLoadedWorkspace: Bool {
        coreWorkspace.loaded || !projectDirectory.isEmpty
    }

    func isChatUnread(_ card: Dieter_V1_Card) -> Bool {
        unreadRule.value(card.id, input: card) { SharedRules.shared.isUnread(card: card.rulesData) }
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

    /// This Mac's own machine, reached over loopback, when it is enrolled.
    var localMachine: MachineEndpoint? {
        endpoints.first { machineEntry($0)?.local == true }
    }

    /// The machine that hosts `projectID`'s work and project-wide reads, as
    /// the core picks it; nil when no listed machine has a checkout of it.
    func projectMachine(forProjectID projectID: String) -> MachineEndpoint? {
        guard let daemonID = projectHosts[projectID] else { return nil }
        return endpoints.first { $0.daemonID == daemonID }
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

    /// Every card the board shows, lane by lane.
    var displayedCards: [Dieter_V1_Card] {
        boardProjection.displayedCards
    }

    /// What `card` shows and offers: the board view's flags while the board
    /// shows it, else the core's rules over the card, e.g. in the Inbox.
    func cardFlags(_ card: Dieter_V1_Card, board: Dieter_V1_Board?) -> ClientBoardCardFlags {
        if let flags = boardCardFlags[card.id] { return flags }
        let inputs = CardFlagInputs(
            card: card, board: board, operation: boardState.operations[card.id] ?? "",
            pending: outboxState.pendingCardIds.contains(card.id), failed: outboxState.failures[card.id] != nil)
        return cardFlagsRule.value(card.id, input: inputs) {
            ClientBoardCardFlags(
                rules: SharedRules.shared.cardFlags(
                    card: card.rulesData, board: board?.rulesData ?? Data(), operation: inputs.operation,
                    pending: inputs.pending, failed: inputs.failed))
        }
    }

    func refreshBoardProjection() {
        bindBoardView()
        let next = BoardProjection.resolve(view: boardView, board: selectedBoard, cards: state.cards)
        if next != boardProjection { boardProjection = next }
        if boardCardFlags != next.view.cards { boardCardFlags = next.view.cards }
        // The chrome observes its own summary, so card updates leave it alone.
        boardViewModel.showChrome(BoardChromeSummary(next.view))
    }

    func boards(for projectID: String) -> [Dieter_V1_Board] {
        navigationBoards[projectID] ?? (projectID == state.project.id ? state.boards : [])
    }

    func board(id: String) -> Dieter_V1_Board? {
        guard !id.isEmpty else { return nil }
        // Every project's boards first: the selected project's state mirrors
        // its boards but changes with every card, and views that only show a
        // board must not observe it.
        let listed = navigationBoards.values.lazy.compactMap { boards in
            boards.first(where: { $0.id == id })
        }.first
        return listed ?? state.boards.first(where: { $0.id == id })
    }
}

/// The core's rules over a card take it encoded, and rows ask while they render.
private let unreadRule = SharedRuleEntityMemo<Dieter_V1_Card, Bool>()
private let cardFlagsRule = SharedRuleEntityMemo<CardFlagInputs, ClientBoardCardFlags>()

/// What the core's card flags rule reads.
private struct CardFlagInputs: Equatable, Sendable {
    let card: Dieter_V1_Card
    let board: Dieter_V1_Board?
    let operation: String
    let pending: Bool
    let failed: Bool
}
