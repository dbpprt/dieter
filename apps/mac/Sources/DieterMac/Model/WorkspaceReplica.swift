import DieterAPI
import Foundation
import Observation

/// App-wide metadata replica and its selected-project projection. Entity updates
/// enter here so boards, global chats, and navigation share one upsert rule.
@MainActor @Observable
final class WorkspaceReplica {
    init() {}

    var state = Dieter_V1_State() {
        didSet {
            if state.projects != oldValue.projects { sortedProjectsCache = nil }
            if state.projects != oldValue.projects || state.boards != oldValue.boards
                || state.cards != oldValue.cards || state.chats != oldValue.chats
            {
                commandSearchRevision &+= 1
            }
        }
    }
    var projectDirectory: [String: Dieter_V1_Project] = [:] {
        didSet {
            if projectDirectory != oldValue {
                sortedProjectsCache = nil
                commandSearchRevision &+= 1
            }
        }
    }
    var projectReplicaEndpointIDs: [String: String] = [:]
    var navigationBoards: [String: [Dieter_V1_Board]] = [:] {
        didSet { if navigationBoards != oldValue { commandSearchRevision &+= 1 } }
    }
    var navigationCards: [String: [Dieter_V1_Card]] = [:] {
        didSet { if navigationCards != oldValue { commandSearchRevision &+= 1 } }
    }
    var retiredBoards: [String: Dieter_V1_Board] = [:]
    var chats: [Dieter_V1_Card] = [] {
        didSet {
            if chats != oldValue { commandSearchRevision &+= 1 }
        }
    }
    var chatProjects: [Dieter_V1_Project] = []
    private(set) var commandSearchRevision: UInt64 = 0
    @ObservationIgnored private var sortedProjectsCache: [Dieter_V1_Project]?

    /// The core's order of the workspace's projects.
    var projectOrder: [String] = [] { didSet { if projectOrder != oldValue { sortedProjectsCache = nil } } }

    /// The projects in the core's order; any the core has not ordered yet follow by ID.
    var projects: [Dieter_V1_Project] {
        // Read the observable sources even when the derived value is cached.
        let directory = projectDirectory
        let order = projectOrder
        if directory.isEmpty { return state.projects }
        if let sortedProjectsCache { return sortedProjectsCache }
        let ordered = order.compactMap { directory[$0] }
        let listed = Set(order)
        let sorted = ordered + directory.values.filter { !listed.contains($0.id) }.sorted { $0.id < $1.id }
        sortedProjectsCache = sorted
        return sorted
    }
}
