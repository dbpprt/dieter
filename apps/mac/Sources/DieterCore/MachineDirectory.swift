import DieterAPI
import Foundation

package struct MachineSnapshot: Sendable {
    package let endpoint: DieterEndpoint
    package let replicaID: String
    package let connection: MachineConnectionStatus
    package let projects: [Dieter_V1_Project]
    package let boards: [Dieter_V1_Board]
    package let cards: [Dieter_V1_Card]
    package let chats: [Dieter_V1_Card]
    package let archives: Dieter_V1_SharedArchives
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
        unchanged: Bool = false,
        replicaID: String? = nil,
        archives: Dieter_V1_SharedArchives = .init()
    ) {
        self.archives = archives
        self.endpoint = endpoint
        self.replicaID = replicaID ?? endpoint.id
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
        projects: [String: Dieter_V1_Project], projectReplicaEndpointIDs: [String: String],
        boards: [String: [Dieter_V1_Board]], cards: [String: [Dieter_V1_Card]], chats: [Dieter_V1_Card]
    ) {
        self.projects = projects; self.projectReplicaEndpointIDs = projectReplicaEndpointIDs; self.boards = boards;
        self.cards = cards; self.chats = chats
    }
    package var projects: [String: Dieter_V1_Project]
    package var projectReplicaEndpointIDs: [String: String]
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
        guard !changedSnapshots.isEmpty else { return current }
        let refreshed = Set(changedSnapshots.map(\.replicaID))
        let incomingIDs = Set(changedSnapshots.flatMap { $0.projects.map(\.id) })
        var next = current
        // An absent project can leave this replica's catalog. A shared project
        // present in another snapshot keeps the union of its owned items.
        for id in current.projects.keys
        where !incomingIDs.contains(id) && refreshed.contains(current.projectReplicaEndpointIDs[id] ?? "") {
            next.projects.removeValue(forKey: id); next.projectReplicaEndpointIDs.removeValue(forKey: id)
            next.boards.removeValue(forKey: id); next.cards.removeValue(forKey: id)
            next.chats.removeAll { $0.projectID == id }
        }
        let allKnownItems =
            current.cards.values.flatMap { $0 } + current.chats + changedSnapshots.flatMap { $0.cards + $0.chats }
        var removed = Set(changedSnapshots.flatMap { $0.archives.itemIds })
        let archivedProjects = Set(changedSnapshots.flatMap { $0.archives.projectIds })
        for snapshot in changedSnapshots {
            guard let owner = snapshot.endpoint.daemonID else { continue }
            let present = Set((snapshot.cards + snapshot.chats).map(\.id))
            // Only an owner's complete snapshot can retire a missing item.
            removed.formUnion(allKnownItems.filter { $0.ownerDaemonID == owner && !present.contains($0.id) }.map(\.id))
        }
        var items = Dictionary(
            (current.cards.values.flatMap { $0 } + current.chats).map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        for snapshot in changedSnapshots {
            for project in snapshot.projects {
                next.projects[project.id] = mergeProject(next.projects[project.id], project)
                next.projectReplicaEndpointIDs[project.id] = snapshot.replicaID
            }
            for board in snapshot.boards {
                var values = next.boards[board.projectID] ?? []
                if let index = values.firstIndex(where: { $0.id == board.id }) {
                    values[index] = board
                } else {
                    values.append(board)
                }
                next.boards[board.projectID] = values.sorted { $0.id < $1.id }
            }
            for item in snapshot.cards + snapshot.chats {
                items[item.id] = item
            }
        }
        for id in archivedProjects {
            next.projects.removeValue(forKey: id); next.projectReplicaEndpointIDs.removeValue(forKey: id)
            next.boards.removeValue(forKey: id)
        }
        let visible = items.values.filter {
            (!removed.contains($0.id) || $0.archived && $0.scope == "chat" && $0.boardID.isEmpty)
                && next.projects[$0.projectID] != nil
        }
        next.cards = Dictionary(
            grouping: visible.filter { $0.scope != "chat" || !$0.boardID.isEmpty }.sorted { $0.id < $1.id },
            by: \.projectID)
        next.chats = visible.filter { $0.scope == "chat" && $0.boardID.isEmpty }.sorted {
            let left = $0.lastActivityAt.isEmpty ? $0.updatedAt : $0.lastActivityAt
            let right = $1.lastActivityAt.isEmpty ? $1.updatedAt : $1.lastActivityAt
            return left == right ? $0.id < $1.id : left > right
        }
        return next
    }

    package static func mergeProject(_ previous: Dieter_V1_Project?, _ incoming: Dieter_V1_Project) -> Dieter_V1_Project
    {
        guard let previous else { return incoming }
        var result = incoming
        var checkouts = Dictionary(previous.checkouts.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        for checkout in incoming.checkouts {
            if checkouts[checkout.id]?.detached == true && !checkout.detached { continue }
            var merged = checkout
            if merged.path.isEmpty {
                merged.path = checkouts[checkout.id]?.path ?? ""
                merged.validationCommands = checkouts[checkout.id]?.validationCommands ?? []
            }
            checkouts[checkout.id] = merged
        }
        result.checkouts = checkouts.values.sorted { $0.id < $1.id }
        return result
    }
}

package enum MachineConnectionRoute: String, Sendable {
    case local = "Local"
    case gateway = "Gateway relay"
    case directTLS = "Direct TLS"
    case webrtcDirect = "WebRTC · Direct"
    case webrtcTURN = "WebRTC · TURN"
    case webrtc = "WebRTC"
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
    case nonLoopback

    package func ordered(_ candidates: [Dieter_Gateway_V1_DirectCandidate]) -> [Dieter_Gateway_V1_DirectCandidate] {
        candidates
            .filter { candidate in
                switch self {
                case .all: true
                case .loopbackOnly: candidate.network.caseInsensitiveCompare("loopback") == .orderedSame
                case .nonLoopback:
                    candidate.network.caseInsensitiveCompare("loopback") != .orderedSame
                        && !DieterEndpoint.isLoopbackHost(candidate.host)
                }
            }
            .sorted { $0.priority > $1.priority }
    }
}
