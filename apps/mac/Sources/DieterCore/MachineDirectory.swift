import DieterAPI
import Foundation

package struct MachineSnapshot: Sendable {
    package let endpoint: DieterEndpoint
    package let connection: MachineConnectionStatus
    package let projects: [Dieter_V1_Project]
    package let boards: [Dieter_V1_Board]
    package let cards: [Dieter_V1_Card]
    package let chats: [Dieter_V1_Card]
    package let cursor: Data?
    package let unchanged: Bool

    package init(
        endpoint: DieterEndpoint,
        connection: MachineConnectionStatus,
        projects: [Dieter_V1_Project],
        boards: [Dieter_V1_Board],
        cards: [Dieter_V1_Card],
        chats: [Dieter_V1_Card],
        cursor: Data? = nil,
        unchanged: Bool = false
    ) {
        self.endpoint = endpoint
        self.connection = connection
        self.projects = projects
        self.boards = boards
        self.cards = cards
        self.chats = chats
        self.cursor = cursor
        self.unchanged = unchanged
    }
}

package struct MachineDirectoryProjection: Equatable {
    package init(
        projects: [String: Dieter_V1_Project], projectEndpointIDs: [String: String],
        boards: [String: [Dieter_V1_Board]], cards: [String: [Dieter_V1_Card]], chats: [Dieter_V1_Card]
    ) {
        self.projects = projects; self.projectEndpointIDs = projectEndpointIDs; self.boards = boards;
        self.cards = cards; self.chats = chats
    }
    package var projects: [String: Dieter_V1_Project]
    package var projectEndpointIDs: [String: String]
    package var boards: [String: [Dieter_V1_Board]]
    package var cards: [String: [Dieter_V1_Card]]
    package var chats: [Dieter_V1_Card]

    package var sortedProjects: [Dieter_V1_Project] {
        projects.values.sorted {
            if $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedSame { return $0.id < $1.id }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

package enum MachineDirectoryReducer {
    package static func merging(
        _ current: MachineDirectoryProjection,
        snapshots: [MachineSnapshot]
    ) -> MachineDirectoryProjection {
        let changedSnapshots = snapshots.filter { !$0.unchanged }
        let refreshedEndpointIDs = Set(changedSnapshots.map(\.endpoint.id))
        var nextProjects = current.projects.filter {
            current.projectEndpointIDs[$0.key].map { !refreshedEndpointIDs.contains($0) } ?? false
        }
        var nextProjectEndpoints = current.projectEndpointIDs.filter { !refreshedEndpointIDs.contains($0.value) }
        var nextBoards = current.boards.filter { projectID, _ in nextProjectEndpoints[projectID] != nil }
        var nextCards = current.cards.filter { projectID, _ in nextProjectEndpoints[projectID] != nil }
        var nextChats = current.chats.filter { chat in nextProjectEndpoints[chat.projectID] != nil }

        for snapshot in changedSnapshots {
            let boardsByProject = Dictionary(grouping: snapshot.boards, by: \.projectID)
            let cardsByProject = Dictionary(grouping: snapshot.cards, by: \.projectID)
            for project in snapshot.projects {
                nextProjects[project.id] = project
                nextProjectEndpoints[project.id] = snapshot.endpoint.id
                nextBoards[project.id] = boardsByProject[project.id] ?? []
                nextCards[project.id] = cardsByProject[project.id] ?? []
            }
            nextChats.append(contentsOf: snapshot.chats)
        }
        let chats =
            nextChats
            .filter { $0.scope == "chat" && $0.boardID.isEmpty }
            .reduce(into: [String: Dieter_V1_Card]()) { $0[$1.id] = $1 }
            .values
            .sorted {
                let lhsActivity = $0.lastActivityAt.isEmpty ? $0.updatedAt : $0.lastActivityAt
                let rhsActivity = $1.lastActivityAt.isEmpty ? $1.updatedAt : $1.lastActivityAt
                if lhsActivity == rhsActivity { return $0.id < $1.id }
                return lhsActivity > rhsActivity
            }
        return MachineDirectoryProjection(
            projects: nextProjects,
            projectEndpointIDs: nextProjectEndpoints,
            boards: nextBoards,
            cards: nextCards,
            chats: chats
        )
    }
}

package enum MachineConnectionRoute: String, Sendable {
    case local = "Local"
    case gateway = "Gateway"
}

package struct MachineConnectionStatus: Equatable, Sendable {
    package init(route: MachineConnectionRoute, latencyMilliseconds: Int) {
        self.route = route; self.latencyMilliseconds = latencyMilliseconds
    }
    package let route: MachineConnectionRoute
    package let latencyMilliseconds: Int
}

package enum DirectCandidateScope: Equatable {
    case all
    case loopbackOnly

    package func ordered(_ candidates: [Dieter_Gateway_V1_DirectCandidate]) -> [Dieter_Gateway_V1_DirectCandidate] {
        candidates
            .filter { self == .all || $0.network.caseInsensitiveCompare("loopback") == .orderedSame }
            .sorted { $0.priority > $1.priority }
    }
}
