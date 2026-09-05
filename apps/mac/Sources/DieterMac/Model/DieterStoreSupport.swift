import AppKit
import DieterAPI
import Foundation
import GRPCCore
import Observation
import OSLog
import UniformTypeIdentifiers
import UserNotifications

let dieterExpectedAPIVersion = "3"
let conversationPageSize: Int32 = 30
let schedulePageSize: Int32 = 50
let syncConversationMessageLimit: Int32 = 30
let syncRecentConversationLimit: Int32 = 8
let cachedConversationLimit = 24
let terminalClientBufferLimit = 2 * 1_024 * 1_024
let outboxLogger = Logger(subsystem: "com.dbpprt.dieter.mac", category: "Outbox")
let connectionLogger = Logger(subsystem: "com.dbpprt.dieter.mac", category: "Connection")
let syncPerformanceLog = OSLog(subsystem: "com.dbpprt.dieter.mac", category: "SyncPerformance")

struct TerminalScreenState: Equatable, Sendable {
    var data = Data()
    var revision = 0
    var resetRevision = 0
}

enum TerminalScreenReducer {
    static func applying(
        data: Data,
        screenReset: Bool,
        to current: TerminalScreenState,
        limit: Int = terminalClientBufferLimit
    ) -> TerminalScreenState {
        var result = current
        if screenReset {
            result.data = data
            result.resetRevision += 1
        } else {
            result.data.append(data)
        }
        if result.data.count > limit {
            result.data = Data(result.data.suffix(limit))
            result.resetRevision += 1
        }
        result.revision += 1
        return result
    }
}

actor TerminalInputForwarder {
    private var pending: [String: Data] = [:]
    private var flushing: Set<String> = []

    func enqueue(id: String, data: Data, rpc: DieterRPC) async -> String? {
        guard !data.isEmpty else { return nil }
        pending[id, default: Data()].append(data)
        guard flushing.insert(id).inserted else { return nil }
        defer { flushing.remove(id) }
        do {
            while !Task.isCancelled {
                try await DieterTaskSleep.milliseconds(12)
                guard let chunk = pending.removeValue(forKey: id), !chunk.isEmpty else { return nil }
                var offset = 0
                while offset < chunk.count {
                    let end = min(chunk.count, offset + (64 * 1_024))
                    _ = try await rpc.writeTerminal(id: id, data: chunk.subdata(in: offset..<end))
                    offset = end
                }
                if pending[id]?.isEmpty != false { return nil }
            }
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case board = "Board"
    case chats = "All chats"
    case terminals = "Terminals"
	case screens = "Screens"
    case files = "Files"
    case schedules = "Schedules"
    case archive = "Archive"
    case settings = "Settings"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .board: "rectangle.split.3x1"
        case .chats: "bubble.left.and.bubble.right"
        case .terminals: "terminal"
		case .screens: "rectangle.inset.filled.and.person.filled"
        case .files: "doc.on.doc"
        case .schedules: "calendar.badge.clock"
        case .archive: "archivebox"
        case .settings: "gearshape"
        }
    }
}

struct MachineSnapshot {
    let endpoint: DieterEndpoint
    let connection: MachineConnectionStatus
    let projects: [Dieter_V1_Project]
    let boards: [Dieter_V1_Board]
    let cards: [Dieter_V1_Card]
    let chats: [Dieter_V1_Card]
    let cursor: Data?
    let unchanged: Bool

    init(
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

struct MachineDirectoryProjection: Equatable {
    var projects: [String: Dieter_V1_Project]
    var projectEndpointIDs: [String: String]
    var boards: [String: [Dieter_V1_Board]]
    var cards: [String: [Dieter_V1_Card]]
    var chats: [Dieter_V1_Card]

    var sortedProjects: [Dieter_V1_Project] {
        projects.values.sorted {
            if $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedSame { return $0.id < $1.id }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

enum MachineDirectoryReducer {
    static func merging(
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
        let chats = nextChats
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

struct DataPlaneConnection {
    let rpc: DieterRPC
    let task: Task<Void, Never>
    let connection: MachineConnectionStatus
    let directTokenExpiresAt: String?
}

enum DirectCandidateScope: Equatable {
    case all
    case loopbackOnly

    func ordered(_ candidates: [Dieter_Gateway_V1_DirectCandidate]) -> [Dieter_Gateway_V1_DirectCandidate] {
        candidates
            .filter { self == .all || $0.network.caseInsensitiveCompare("loopback") == .orderedSame }
            .sorted { $0.priority > $1.priority }
    }
}

enum DieterStoreConnectionError: LocalizedError {
    case incompatible(found: String)
    case syncEnded
    case syncTimedOut

    var errorDescription: String? {
        switch self {
        case let .incompatible(found):
            "Dieter API \(found.isEmpty ? "unknown" : found) is incompatible; macOS requires \(dieterExpectedAPIVersion)."
        case .syncEnded:
            "Live updates stopped unexpectedly."
        case .syncTimedOut:
            "Live updates stopped responding."
        }
    }
}

enum SyncStreamLiveness {
    static let timeout: TimeInterval = 45

    static func requiresConnectionRecovery(lastFrameAt: Date?, now: Date = Date()) -> Bool {
        guard let lastFrameAt else { return true }
        return now.timeIntervalSince(lastFrameAt) >= timeout
    }
}

enum ConnectionAttemptOwnership {
    static func mayMutateSharedState(attemptGeneration: UInt64, currentGeneration: UInt64) -> Bool {
        attemptGeneration == currentGeneration
    }
}

enum MachineAPICompatibility: Equatable, Sendable {
	case compatible
	case incompatible
	case unknown
}

extension DieterEndpoint {
	var apiCompatibility: MachineAPICompatibility {
		guard !apiVersion.isEmpty else { return .unknown }
		return apiVersion == dieterExpectedAPIVersion ? .compatible : .incompatible
	}

	var incompatibilityDescription: String? {
		guard apiCompatibility == .incompatible else { return nil }
		return "Update required · API \(apiVersion) (requires \(dieterExpectedAPIVersion))"
	}
}

enum OutboxWorkerOwnership {
    static func mayClearTask(workerGeneration: UInt64, currentGeneration: UInt64) -> Bool {
        workerGeneration == currentGeneration
    }
}

enum SyncFreshnessPresentation {
    static func lastConnectedLabel(lastConnectedAt: Date?, now: Date = Date()) -> String {
        guard let lastConnectedAt else { return "Last connected unknown" }
        return relativeLabel(prefix: "Last connected", date: lastConnectedAt, now: now)
    }

    static func lastUpdateLabel(lastUpdatedAt: Date?, now: Date = Date()) -> String {
        guard let lastUpdatedAt else { return "Not updated yet" }
        return relativeLabel(prefix: "Updated", date: lastUpdatedAt, now: now)
    }

    private static func relativeLabel(prefix: String, date: Date, now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        switch elapsed {
        case ..<60:
            return "\(prefix) just now"
        case ..<3_600:
            return "\(prefix) \(max(1, Int(elapsed / 60)))m ago"
        case ..<86_400:
            return "\(prefix) \(max(1, Int(elapsed / 3_600)))h ago"
        default:
            return "\(prefix) \(max(1, Int(elapsed / 86_400)))d ago"
        }
    }
}

enum WorkspaceFreshnessState: Equatable {
    case live
    case syncing
    case reconnecting
    case offline

    static func resolve(
        phase: ConnectionPhase,
        globalSyncing: Bool,
        hasCachedWorkspace: Bool
    ) -> Self {
        if phase.isConnected { return globalSyncing ? .syncing : .live }
        if phase == .connecting, hasCachedWorkspace { return .reconnecting }
        return .offline
    }

    var isLive: Bool { self == .live }

    var label: String {
        switch self {
        case .live: "Online"
        case .syncing: "Syncing"
        case .reconnecting: "Reconnecting"
        case .offline: "Offline"
        }
    }
}

enum SyncCursorPersistencePolicy {
    // A five-minute checkpoint keeps a 4 MiB projection below 50 MiB of
    // logical writes per hour. Deactivation and durability-sensitive outbox
    // mutations explicitly flush sooner.
    static let interval: TimeInterval = 5 * 60

    static func shouldPersist(projectionChanged: Bool, lastPersistedAt: Date?, now: Date) -> Bool {
        // The in-memory snapshot and cursor advance together. Persisting an
        // older pair is safe because WatchSync will replay the later delta, so
        // high-frequency conversation frames do not need a multi-megabyte
        // atomic disk write each time.
        guard projectionChanged else { return false }
        return lastPersistedAt.map { now.timeIntervalSince($0) >= interval } ?? true
    }
}

enum MachineConnectionRoute: String, Sendable {
    case local = "Local"
    case gateway = "Gateway"
}

struct MachineConnectionStatus: Equatable, Sendable {
    let route: MachineConnectionRoute
    let latencyMilliseconds: Int
}

struct MachineOutboxSummary: Equatable, Sendable {
    let messageCount: Int
    let changeCount: Int
    let retrying: Bool
    let failed: Bool

    var itemCount: Int { messageCount + changeCount }

    var deliveryLabel: String {
        let noun: String
        if changeCount == 0 {
            noun = messageCount == 1 ? "message" : "messages"
        } else if messageCount == 0 {
            noun = changeCount == 1 ? "change" : "changes"
        } else {
            noun = itemCount == 1 ? "item" : "items"
        }
        let suffix = failed ? "needs attention." : "delivers when it reconnects."
        return "\(itemCount) \(noun) queued — \(suffix)"
    }

    static func summaries(for entries: [DieterOutboxEntry]) -> [String: MachineOutboxSummary] {
        Dictionary(grouping: entries.filter { $0.serverID == nil }, by: \.endpointID)
            .mapValues { pending in
                MachineOutboxSummary(
                    messageCount: pending.count { $0.kind == .sendMessage },
                    changeCount: pending.count { $0.kind != .sendMessage },
                    retrying: pending.contains { $0.state == .retrying },
                    failed: pending.contains { $0.state == .failed }
                )
            }
    }
}

struct DieterFailedOutboxItem: Identifiable, Sendable {
    let id: String
    let operation: String
    let targetID: String
    let failure: String
    let createdAt: Date
}

struct ProjectFileNavigation: Equatable, Sendable {
    private static let historyLimit = 100
    private(set) var backwardPaths: [String] = []
    private(set) var forwardPaths: [String] = []

    var canGoBack: Bool { !backwardPaths.isEmpty }
    var canGoForward: Bool { !forwardPaths.isEmpty }

    static func parentPath(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }

    mutating func recordNavigation(from currentPath: String, to destinationPath: String) {
        guard currentPath != destinationPath else { return }
        Self.append(currentPath, to: &backwardPaths)
        forwardPaths.removeAll(keepingCapacity: true)
    }

    mutating func goBack(from currentPath: String) -> String? {
        guard let destination = backwardPaths.popLast() else { return nil }
        Self.append(currentPath, to: &forwardPaths)
        return destination
    }

    mutating func goForward(from currentPath: String) -> String? {
        guard let destination = forwardPaths.popLast() else { return nil }
        Self.append(currentPath, to: &backwardPaths)
        return destination
    }

    mutating func reset() {
        backwardPaths.removeAll(keepingCapacity: true)
        forwardPaths.removeAll(keepingCapacity: true)
    }

    private static func append(_ path: String, to history: inout [String]) {
        history.append(path)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
    }
}

enum MachineRoutingPolicy {
	static func preferredDaemonID(newEndpoint: DieterEndpoint?, currentEndpoint: DieterEndpoint) -> String? {
		newEndpoint?.daemonID ?? (newEndpoint == nil ? currentEndpoint.daemonID : nil)
	}

    static func automaticConnectionTarget(
        from machines: [DieterEndpoint],
        preferredDaemonID: String?
    ) -> DieterEndpoint? {
		connectionTargets(
			from: machines,
			preferredDaemonID: preferredDaemonID,
			explicitMachineSelection: false
		).first
	}

	static func connectionTargets(
		from machines: [DieterEndpoint],
		preferredDaemonID: String?,
		explicitMachineSelection: Bool
	) -> [DieterEndpoint] {
		let online = machines.filter(\.online)
		if explicitMachineSelection, let preferredDaemonID {
			return online.filter { $0.daemonID == preferredDaemonID }
		}
		let eligible = online.filter { $0.apiCompatibility != .incompatible }
		let sorted = eligible.sorted {
			let leftRank = $0.apiCompatibility == .compatible ? 0 : 1
			let rightRank = $1.apiCompatibility == .compatible ? 0 : 1
			if leftRank != rightRank { return leftRank < rightRank }
			let names = $0.name.localizedCaseInsensitiveCompare($1.name)
			if names != .orderedSame { return names == .orderedAscending }
			return $0.id < $1.id
		}
		guard let preferredIndex = sorted.firstIndex(where: { $0.daemonID == preferredDaemonID }) else {
			return sorted
		}
		var result = sorted
		let preferred = result.remove(at: preferredIndex)
		result.insert(preferred, at: 0)
		return result
    }
}

struct OptimisticCardMove: Equatable, Sendable {
    let operationID: UUID
    var lane: String
    var position: Int64
    var confirmsPosition: Bool

    func isConfirmed(by card: Dieter_V1_Card) -> Bool {
        card.lane == lane && (!confirmsPosition || card.position == position)
    }

    func applying(to card: Dieter_V1_Card) -> Dieter_V1_Card {
        var card = card
        card.lane = lane
        card.position = position
        return card
    }
}

struct OptimisticCardLabels: Equatable, Sendable {
    let operationID: UUID
    let labelIDs: [String]

    func isConfirmed(by card: Dieter_V1_Card) -> Bool {
        card.labelIds == labelIDs
    }

    func applying(to card: Dieter_V1_Card) -> Dieter_V1_Card {
        var card = card
        card.labelIds = labelIDs
        return card
    }
}

struct OptimisticCardProjection {
    let cards: [Dieter_V1_Card]
    let moves: [String: OptimisticCardMove]
    let labels: [String: OptimisticCardLabels]

    static func reconcile(
        cards: [Dieter_V1_Card],
        moves: [String: OptimisticCardMove],
        labels: [String: OptimisticCardLabels]
    ) -> OptimisticCardProjection {
        var remainingMoves = moves
        var remainingLabels = labels
        let projected = cards.map { serverCard in
            var card = serverCard
            if let move = moves[card.id] {
                if move.isConfirmed(by: serverCard) { remainingMoves.removeValue(forKey: card.id) }
                else { card = move.applying(to: card) }
            }
            if let labelUpdate = labels[card.id] {
                if labelUpdate.isConfirmed(by: serverCard) { remainingLabels.removeValue(forKey: card.id) }
                else { card = labelUpdate.applying(to: card) }
            }
            return card
        }
        return .init(cards: projected, moves: remainingMoves, labels: remainingLabels)
    }
}

struct OptimisticWorkspaceProjection {
    static func reconcileBoards(
        _ serverBoards: [Dieter_V1_Board],
        pending: [String: Dieter_V1_Board]
    ) -> (boards: [Dieter_V1_Board], pending: [String: Dieter_V1_Board]) {
        var remaining = pending
        let boards = serverBoards.map { serverBoard in
            guard let expected = pending[serverBoard.id] else { return serverBoard }
            if serverBoard == expected {
                remaining.removeValue(forKey: serverBoard.id)
                return serverBoard
            }
            return expected
        }
        return (boards, remaining)
    }

    static func reconcileProjects(
        _ serverProjects: [Dieter_V1_Project],
        pending: [String: Dieter_V1_Project]
    ) -> (projects: [Dieter_V1_Project], pending: [String: Dieter_V1_Project]) {
        var remaining = pending
        let projects = serverProjects.map { serverProject in
            guard let expected = pending[serverProject.id] else { return serverProject }
            if serverProject == expected {
                remaining.removeValue(forKey: serverProject.id)
                return serverProject
            }
            return expected
        }
        return (projects, remaining)
    }
}

enum DieterAttachmentError: LocalizedError {
    case tooMany
    case fileTooLarge(String)
    case totalTooLarge
    case empty(String)
    case notAFile(String)
    case unsupportedPaste
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .tooMany: "You can attach up to 4 images or files."
        case .fileTooLarge(let name): "\(name) must be at most 5 MB."
        case .totalTooLarge: "Attachments must total at most 6 MB."
        case .empty(let name): "\(name) is empty."
        case .notAFile(let name): "\(name) is not a regular file."
        case .unsupportedPaste: "The clipboard does not contain an image or file that Dieter can attach."
        case .invalidImage: "The pasted image could not be decoded."
        }
    }
}
