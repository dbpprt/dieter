import DieterAPI
import Foundation
import Observation

/// App-wide metadata replica and its selected-project projection. Entity updates
/// enter here so boards, global chats, and navigation share one upsert rule.
@MainActor @Observable
package final class WorkspaceReplica {
    package init() {}
    package var pendingCardStarts: [String: OptimisticCardStart] = [:]
    package var pendingCardMoves: [String: OptimisticCardMove] = [:]
    package var pendingCardLabelUpdates: [String: OptimisticCardLabels] = [:]
    package var pendingBoards: [String: Dieter_V1_Board] = [:]
    package var pendingProjects: [String: Dieter_V1_Project] = [:]

    package func reconcile(_ received: Dieter_V1_State) -> Dieter_V1_State {
        var next = received
        let boards = OptimisticWorkspaceProjection.reconcileBoards(next.boards, pending: pendingBoards)
        next.boards = boards.boards; pendingBoards = boards.pending
        let projects = OptimisticWorkspaceProjection.reconcileProjects(next.projects, pending: pendingProjects)
        next.projects = projects.projects; pendingProjects = projects.pending
        let cards = OptimisticCardProjection.reconcile(
            cards: next.cards, moves: pendingCardMoves, labels: pendingCardLabelUpdates, starts: pendingCardStarts)
        next.cards = cards.cards; pendingCardMoves = cards.moves; pendingCardLabelUpdates = cards.labels;
        pendingCardStarts = cards.starts
        return next
    }

    package var state = Dieter_V1_State() {
        didSet { if state.projects != oldValue.projects { sortedProjectsCache = nil } }
    }
    package var projectDirectory: [String: Dieter_V1_Project] = [:] {
        didSet { if projectDirectory != oldValue { sortedProjectsCache = nil } }
    }
    package var projectEndpointIDs: [String: String] = [:]
    package var navigationBoards: [String: [Dieter_V1_Board]] = [:]
    package var navigationCards: [String: [Dieter_V1_Card]] = [:]
    package var chats: [Dieter_V1_Card] = [] { didSet { if chats != oldValue { chatRevision &+= 1; chatCache = nil } } }
    package var chatProjects: [Dieter_V1_Project] = []
    private(set) var chatRevision: UInt64 = 0
    @ObservationIgnored private var sortedProjectsCache: [Dieter_V1_Project]?
    @ObservationIgnored private var chatCache:
        (revision: UInt64, archived: Bool, search: String, order: [String], projection: ChatListProjection)?

    package var projects: [Dieter_V1_Project] {
        // Read the observable sources even when the derived value is cached.
        let values = projectDirectory.isEmpty ? state.projects : Array(projectDirectory.values)
        if let sortedProjectsCache { return sortedProjectsCache }
        let sorted = values.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        sortedProjectsCache = sorted
        return sorted
    }

    package func chatProjection(showArchived: Bool, search: String, pinnedOrder: [String]) -> ChatListProjection {
        let revision = chatRevision
        if let cached = chatCache, cached.revision == revision, cached.archived == showArchived,
            cached.search == search, cached.order == pinnedOrder
        {
            return cached.projection
        }
        let projection = ChatListProjection.resolve(
            chats: chats, showArchived: showArchived, search: search, pinnedOrder: pinnedOrder)
        chatCache = (revision, showArchived, search, pinnedOrder, projection)
        return projection
    }

    package var directory: MachineDirectoryProjection {
        MachineDirectoryProjection(
            projects: projectDirectory, projectEndpointIDs: projectEndpointIDs,
            boards: navigationBoards, cards: navigationCards, chats: chats)
    }

    package func accept(_ projection: MachineDirectoryProjection) {
        if projectDirectory != projection.projects { projectDirectory = projection.projects }
        if projectEndpointIDs != projection.projectEndpointIDs { projectEndpointIDs = projection.projectEndpointIDs }
        if navigationBoards != projection.boards { navigationBoards = projection.boards }
        if navigationCards != projection.cards { navigationCards = projection.cards }
        if chats != projection.chats { chats = projection.chats }
        if chatProjects != projects { chatProjects = projects }
    }

    package func replaceMetadata(_ incoming: Dieter_V1_State, endpointID: String) {
        let previousIDs = Set(projectEndpointIDs.compactMap { $0.value == endpointID ? $0.key : nil })
        var next = directory
        for id in previousIDs {
            next.projects.removeValue(forKey: id); next.projectEndpointIDs.removeValue(forKey: id)
            next.boards.removeValue(forKey: id); next.cards.removeValue(forKey: id)
        }
        let boards = Dictionary(grouping: incoming.boards, by: \.projectID)
        let cards = Dictionary(grouping: incoming.cards, by: \.projectID)
        for project in incoming.projects {
            next.projects[project.id] = project; next.projectEndpointIDs[project.id] = endpointID
            next.boards[project.id] = boards[project.id] ?? []; next.cards[project.id] = cards[project.id] ?? []
        }
        let merged = next.chats.filter { !previousIDs.contains($0.projectID) } + incoming.chats
        next.chats = Array(merged.reduce(into: [String: Dieter_V1_Card]()) { $0[$1.id] = $1 }.values).sorted {
            let left = $0.lastActivityAt.isEmpty ? $0.updatedAt : $0.lastActivityAt
            let right = $1.lastActivityAt.isEmpty ? $1.updatedAt : $1.lastActivityAt
            return left == right ? $0.id < $1.id : left > right
        }
        accept(next)
    }

    package func upsert(_ card: Dieter_V1_Card) {
        guard !card.id.isEmpty else { return }
        if card.scope == "chat", card.boardID.isEmpty {
            Self.upsert(card, in: &chats, id: \.id)
            if state.project.id == card.projectID || state.chats.contains(where: { $0.id == card.id }) {
                Self.upsert(card, in: &state.chats, id: \.id)
            }
        } else {
            Self.upsert(card, in: &navigationCards[card.projectID, default: []], id: \.id)
            if state.project.id == card.projectID || state.cards.contains(where: { $0.id == card.id }) {
                Self.upsert(card, in: &state.cards, id: \.id)
            }
        }
    }

    package func upsert(_ board: Dieter_V1_Board, selectedProjectID: String) {
        Self.upsert(board, in: &navigationBoards[board.projectID, default: []], id: \.id)
        if board.projectID == selectedProjectID { Self.upsert(board, in: &state.boards, id: \.id) }
    }

    package func upsert(_ project: Dieter_V1_Project) {
        projectDirectory[project.id] = project
        Self.upsert(project, in: &state.projects, id: \.id)
        if state.project.id == project.id { state.project = project }
        chatProjects = projects
    }

    private static func upsert<Value: Equatable>(_ value: Value, in values: inout [Value], id: KeyPath<Value, String>) {
        if let index = values.firstIndex(where: { $0[keyPath: id] == value[keyPath: id] }) {
            if values[index] != value { values[index] = value }
        } else {
            values.append(value)
        }
    }
}
