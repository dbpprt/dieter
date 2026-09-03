import AppKit
import DieterAPI
import Foundation
import GRPCCore
import Observation
import OSLog
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

    var projects: [Dieter_V1_Project] {
        let values = projectDirectory.isEmpty ? state.projects : Array(projectDirectory.values)
        return values.sorted {
            if $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedSame { return $0.id < $1.id }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// The daemon-wide card projection used by app-global surfaces such as the
    /// Island. `state.cards` intentionally contains only the selected project,
    /// while `navigationCards` is kept current by WatchSync in the background.
    var synchronizedCards: [Dieter_V1_Card] {
        synchronizedCardValues().sorted {
            let lhsActivity = $0.lastActivityAt.isEmpty ? $0.updatedAt : $0.lastActivityAt
            let rhsActivity = $1.lastActivityAt.isEmpty ? $1.updatedAt : $1.lastActivityAt
            if lhsActivity == rhsActivity { return $0.id < $1.id }
            return lhsActivity > rhsActivity
        }
    }

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

    func refreshIslandActivityProjection(now: Date = Date()) {
        guard !suppressIslandActivityRefresh else { return }
        let source = DieterIslandActivity.source(cards: synchronizedCardValues())
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: now)
        guard source != islandActivitySource || day != islandActivityDay else { return }
        islandActivitySource = source
        islandActivityDay = day
        os_signpost(.begin, log: syncPerformanceLog, name: "Derive Island activity")
        islandActivity = DieterIslandActivity.resolve(source: source, now: now, calendar: calendar)
        os_signpost(.end, log: syncPerformanceLog, name: "Derive Island activity")
        islandActivityProjectionRevision += 1
    }

    func refreshIslandActivityDateBoundaryIfNeeded(now: Date) {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: now)
        guard day != islandActivityDay else { return }
        islandActivityDay = day
        os_signpost(.begin, log: syncPerformanceLog, name: "Derive Island activity")
        islandActivity = DieterIslandActivity.resolve(
            source: islandActivitySource,
            now: now,
            calendar: calendar
        )
        os_signpost(.end, log: syncPerformanceLog, name: "Derive Island activity")
        islandActivityProjectionRevision += 1
    }

    var machines: [DieterEndpoint] {
        endpoints.filter { $0.daemonID != nil }.sorted {
            if $0.online != $1.online { return $0.online && !$1.online }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var gateways: [DieterEndpoint] {
        gatewayOrigins.sorted {
            let lhsPrimary = $0.credentialID == DieterEndpoint.defaults.first?.credentialID
            let rhsPrimary = $1.credentialID == DieterEndpoint.defaults.first?.credentialID
            if lhsPrimary != rhsPrimary { return lhsPrimary }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var activeGateway: DieterEndpoint {
        gatewayOrigins.first(where: { $0.credentialID == endpoint.credentialID }) ?? endpoint.gatewayEndpoint
    }

    var hasLoadedWorkspace: Bool {
        !health.version.isEmpty || !state.projects.isEmpty || !projectDirectory.isEmpty
    }

    func isChatUnread(_ card: Dieter_V1_Card) -> Bool {
        guard selectedChatID != card.id else { return false }
        let activity = card.lastActivityAt.isEmpty ? card.updatedAt : card.lastActivityAt
        guard !activity.isEmpty else { return false }
        guard let read = readChatActivity[card.id] else { return true }
        if let activityDate = Self.parseTimestamp(activity), let readDate = Self.parseTimestamp(read) {
            return activityDate > readDate
        }
        return activity > read
    }

    func isPendingCard(_ id: String) -> Bool { pendingCardIDs.contains(id) }
    func isPendingMessage(_ id: String) -> Bool { pendingMessageIDs.contains(id) }
    func isAcceptedOutboxItem(_ id: String) -> Bool { acceptedOutboxIDs.contains(id) }
    func isFailedOutboxItem(_ id: String) -> Bool { failedOutboxIDs.contains(id) }

    var failedOutboxItems: [DieterFailedOutboxItem] {
        syncDiskState.outbox.compactMap { entry in
            guard entry.state == .failed else { return nil }
            return DieterFailedOutboxItem(
                id: entry.serverID ?? entry.optimisticID,
                operation: entry.kind.rawValue,
                targetID: entry.serverID ?? entry.optimisticID,
                failure: entry.lastError ?? "The queued operation failed.",
                createdAt: entry.createdAt
            )
        }
    }

    func machine(forProjectID projectID: String) -> DieterEndpoint? {
        guard let endpointID = projectEndpointIDs[projectID] else { return nil }
        return endpoints.first { $0.id == endpointID }
    }

    func connectionStatus(for machine: DieterEndpoint) -> MachineConnectionStatus? {
        machineConnectionStatuses[machine.id]
    }

    func outboxSummary(for machine: DieterEndpoint) -> MachineOutboxSummary? {
        machineOutboxSummaries[machine.id]
    }

    var selectedBoard: Dieter_V1_Board? {
        board(id: selectedBoardID)
    }

    var renameBoardTarget: Dieter_V1_Board? {
        board(id: renameBoardTargetID)
    }

    var selectedCard: Dieter_V1_Card? {
        let id = selectedCardID ?? selectedChatID
        return state.cards.first { $0.id == id } ?? state.chats.first { $0.id == id } ?? chats.first { $0.id == id }
    }

    var selectedSchedule: Dieter_V1_Schedule? {
        guard schedulesAreLoaded, let selectedScheduleID else { return nil }
        return schedules.first { $0.id == selectedScheduleID }
    }

    var schedulesAreLoaded: Bool {
        !selectedProjectID.isEmpty &&
            schedulesLoadedProjectID == selectedProjectID &&
            schedulesLoadedEndpointID == endpoint.id
    }

    var selectedTerminal: Dieter_V1_Terminal? {
        guard let selectedTerminalID else { return nil }
        return terminals.first { $0.id == selectedTerminalID }
    }

    var displayedCards: [Dieter_V1_Card] {
        boardProjection.displayedCards
    }

    var boardCards: [Dieter_V1_Card] {
        boardProjection.cards
    }

    func refreshBoardProjection() {
        let next = BoardProjection.resolve(
            cards: state.cards,
            boardID: selectedBoardID,
            runtimeFilter: runtimeFilter,
            labelFilter: labelFilter,
            query: query
        )
        if next != boardProjection { boardProjection = next }
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
