import DieterAPI
import Foundation

package struct DieterOutboxEntry: Codable, Equatable, Identifiable, Sendable {
    package enum Kind: String, Codable, Sendable { case createCard, createChat, sendMessage }
    package enum State: String, Codable, Sendable { case queued, retrying, failed }

    package var id: String { commandID }
    package let commandID: String
    package let clientID: String
    package var endpointID: String
    package let kind: Kind
    package var request: Data
    package let optimisticID: String
    package var serverID: String? = nil
    package var attempts: Int
    package var lastError: String? = nil
    package var state: State = .queued
    package var nextAttemptAt: Date? = nil
    package let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case commandID, clientID, endpointID, daemonID, kind, request, optimisticID, serverID, attempts, lastError,
            state, nextAttemptAt, createdAt
    }

    package init(
        commandID: String,
        clientID: String,
        endpointID: String,
        kind: Kind,
        request: Data,
        optimisticID: String,
        serverID: String? = nil,
        attempts: Int,
        lastError: String? = nil,
        state: State = .queued,
        nextAttemptAt: Date? = nil,
        createdAt: Date
    ) {
        self.commandID = commandID
        self.clientID = clientID
        self.endpointID = endpointID
        self.kind = kind
        self.request = request
        self.optimisticID = optimisticID
        self.serverID = serverID
        self.attempts = attempts
        self.lastError = lastError
        self.state = state
        self.nextAttemptAt = nextAttemptAt
        self.createdAt = createdAt
    }

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        commandID = try values.decode(String.self, forKey: .commandID)
        clientID = try values.decode(String.self, forKey: .clientID)
        endpointID =
            try values.decodeIfPresent(String.self, forKey: .endpointID)
            ?? values.decode(String.self, forKey: .daemonID)
        kind = try values.decode(Kind.self, forKey: .kind)
        request = try values.decode(Data.self, forKey: .request)
        optimisticID = try values.decode(String.self, forKey: .optimisticID)
        serverID = try values.decodeIfPresent(String.self, forKey: .serverID)
        attempts = try values.decode(Int.self, forKey: .attempts)
        lastError = try values.decodeIfPresent(String.self, forKey: .lastError)
        state = try values.decodeIfPresent(State.self, forKey: .state) ?? .queued
        nextAttemptAt = try values.decodeIfPresent(Date.self, forKey: .nextAttemptAt)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
    }

    package func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(commandID, forKey: .commandID)
        try values.encode(clientID, forKey: .clientID)
        try values.encode(endpointID, forKey: .endpointID)
        try values.encode(kind, forKey: .kind)
        try values.encode(request, forKey: .request)
        try values.encode(optimisticID, forKey: .optimisticID)
        try values.encodeIfPresent(serverID, forKey: .serverID)
        try values.encode(attempts, forKey: .attempts)
        try values.encodeIfPresent(lastError, forKey: .lastError)
        try values.encode(state, forKey: .state)
        try values.encodeIfPresent(nextAttemptAt, forKey: .nextAttemptAt)
        try values.encode(createdAt, forKey: .createdAt)
    }
}

package struct DieterSyncProjection: Codable, Sendable {
    package init(cursor: Data?, snapshot: Data?, refreshedAt: Date? = nil) {
        self.cursor = cursor; self.snapshot = snapshot; self.refreshedAt = refreshedAt
    }
    package var cursor: Data?
    package var snapshot: Data?
    /// Wall-clock time of the most recent authoritative WatchSync frame.
    /// Persisting this separately from the snapshot lets the UI report the
    /// age of a cursor-only heartbeat after relaunching.
    package var refreshedAt: Date? = nil

    package static let empty = DieterSyncProjection(cursor: nil, snapshot: nil)
}

package struct DieterSyncDiskState: Codable, Sendable {
    /// Gateway-scoped daemon endpoint ID -> durable metadata projection.
    /// The endpoint ID includes the gateway credential origin, so two gateways
    /// may safely expose daemons with the same daemon ID.
    package var projections: [String: DieterSyncProjection]
    /// Legacy single-daemon fields retained only for an in-place migration.
    package var cursor: Data?
    package var snapshot: Data?
    /// Endpoint ID -> card ID -> the wall-clock time at which the native
    /// client last received authoritative conversation data.
    package var conversationRefreshedAt: [String: [String: Date]]
    package var outbox: [DieterOutboxEntry]

    package init(
        projections: [String: DieterSyncProjection] = [:],
        cursor: Data? = nil,
        snapshot: Data? = nil,
        conversationRefreshedAt: [String: [String: Date]] = [:],
        outbox: [DieterOutboxEntry] = []
    ) {
        self.projections = projections
        self.cursor = cursor
        self.snapshot = snapshot
        self.conversationRefreshedAt = conversationRefreshedAt
        self.outbox = outbox
    }

    private enum CodingKeys: String, CodingKey {
        case projections, cursor, snapshot, conversationRefreshedAt, outbox
    }

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        projections = try values.decodeIfPresent([String: DieterSyncProjection].self, forKey: .projections) ?? [:]
        cursor = try values.decodeIfPresent(Data.self, forKey: .cursor)
        snapshot = try values.decodeIfPresent(Data.self, forKey: .snapshot)
        conversationRefreshedAt =
            try values.decodeIfPresent(
                [String: [String: Date]].self,
                forKey: .conversationRefreshedAt
            ) ?? [:]
        outbox = try values.decodeIfPresent([DieterOutboxEntry].self, forKey: .outbox) ?? []
    }

    package mutating func clearProjections() {
        projections.removeAll()
        cursor = nil
        snapshot = nil
        conversationRefreshedAt.removeAll()
    }

    package static let empty = DieterSyncDiskState()
}

/// A persistence input that keeps the active protobuf projection in its
/// in-memory form until it reaches the persistence executor. This prevents the
/// main actor from serializing a multi-megabyte snapshot for every streamed
/// conversation update.
package struct DieterSyncCheckpoint: Sendable {
    package var diskState: DieterSyncDiskState
    package let activeEndpointID: String
    package let activeSnapshot: Dieter_V1_GlobalSnapshot?

    package init(
        diskState: DieterSyncDiskState,
        activeEndpointID: String = "",
        activeSnapshot: Dieter_V1_GlobalSnapshot? = nil
    ) {
        self.diskState = diskState
        self.activeEndpointID = activeEndpointID
        self.activeSnapshot = activeSnapshot
    }

    package func materialized() throws -> DieterSyncDiskState {
        guard !activeEndpointID.isEmpty, let activeSnapshot else { return diskState }
        var value = diskState
        var projection = value.projections[activeEndpointID] ?? .empty
        projection.snapshot = try activeSnapshot.serializedData()
        value.projections[activeEndpointID] = projection
        return value
    }
}

package enum DieterSyncProjectionCache {
    /// A directory poll is a fresh daemon-wide metadata read. Its response
    /// cursor can be reused for conditional inactive-machine refreshes.
    package static func replacingMetadata(
        in projection: DieterSyncProjection,
        projects: [Dieter_V1_Project],
        boards: [Dieter_V1_Board],
        cards: [Dieter_V1_Card],
        chats: [Dieter_V1_Card],
        cursor: Data? = nil
    ) -> DieterSyncProjection {
        var snapshot =
            projection.snapshot
            .flatMap { try? Dieter_V1_GlobalSnapshot(serializedBytes: $0) }
            ?? Dieter_V1_GlobalSnapshot()
        snapshot.state.projects = projects
        snapshot.state.boards = boards
        snapshot.state.cards = cards
        snapshot.state.chats = chats
        snapshot.schedules = []
        snapshot.scheduleRuns = []
        return DieterSyncProjection(
            cursor: cursor,
            snapshot: try? snapshot.serializedData(),
            refreshedAt: projection.refreshedAt
        )
    }

    package static func cachingConversation(
        _ conversation: Dieter_V1_ConversationSnapshot,
        in projection: DieterSyncProjection,
        limit: Int
    ) -> (projection: DieterSyncProjection, retainedCardIDs: Set<String>) {
        let cardID = conversation.detail.card.id
        var snapshot =
            projection.snapshot
            .flatMap { try? Dieter_V1_GlobalSnapshot(serializedBytes: $0) }
            ?? Dieter_V1_GlobalSnapshot()
        snapshot.schedules = []
        snapshot.scheduleRuns = []
        snapshot.conversations.removeAll { $0.detail.card.id == cardID }
        snapshot.conversations.append(conversation)
        if snapshot.conversations.count > limit {
            snapshot.conversations.removeFirst(snapshot.conversations.count - limit)
        }
        var result = projection
        result.snapshot = try? snapshot.serializedData()
        return (result, Set(snapshot.conversations.map { $0.detail.card.id }))
    }
}

package enum GlobalProjectionReducer {
    package static func changesProjection(_ delta: Dieter_V1_GlobalDelta) -> Bool {
        !delta.projects.isEmpty || !delta.removedProjectIds.isEmpty || !delta.boards.isEmpty
            || !delta.removedBoardIds.isEmpty || !delta.cards.isEmpty || !delta.removedCardIds.isEmpty
            || !delta.chats.isEmpty || !delta.removedChatIds.isEmpty || delta.hasSettings
            || !delta.conversations.isEmpty || !delta.removedConversationIds.isEmpty
    }

    package static func applying(
        _ delta: Dieter_V1_GlobalDelta,
        to snapshot: Dieter_V1_GlobalSnapshot
    ) -> Dieter_V1_GlobalSnapshot {
        var next = snapshot
        next.schedules = []
        next.scheduleRuns = []
        if !delta.projects.isEmpty || !delta.removedProjectIds.isEmpty {
            next.state.projects = merge(
                next.state.projects,
                changed: delta.projects,
                removed: Set(delta.removedProjectIds),
                id: { $0.id }
            )
        }
        if !delta.boards.isEmpty || !delta.removedBoardIds.isEmpty {
            next.state.boards = merge(
                next.state.boards,
                changed: delta.boards,
                removed: Set(delta.removedBoardIds),
                id: { $0.id }
            )
        }
        if !delta.cards.isEmpty || !delta.removedCardIds.isEmpty {
            next.state.cards = merge(
                next.state.cards,
                changed: delta.cards,
                removed: Set(delta.removedCardIds),
                id: { $0.id }
            )
        }
        if !delta.chats.isEmpty || !delta.removedChatIds.isEmpty {
            next.state.chats = merge(
                next.state.chats,
                changed: delta.chats,
                removed: Set(delta.removedChatIds),
                id: { $0.id }
            )
        }
        if !delta.conversations.isEmpty || !delta.removedConversationIds.isEmpty {
            next.conversations = merge(
                next.conversations,
                changed: delta.conversations,
                removed: Set(delta.removedConversationIds),
                id: { $0.detail.card.id }
            )
        }
        if delta.hasSettings { next.settings = delta.settings }
        return next
    }

    package static func changesWorkspace(_ delta: Dieter_V1_GlobalDelta) -> Bool {
        !delta.projects.isEmpty || !delta.removedProjectIds.isEmpty || !delta.boards.isEmpty
            || !delta.removedBoardIds.isEmpty || !delta.cards.isEmpty || !delta.removedCardIds.isEmpty
            || !delta.chats.isEmpty || !delta.removedChatIds.isEmpty || delta.hasSettings
    }

    package static func changesConversationDirectory(_ delta: Dieter_V1_GlobalDelta) -> Bool {
        !delta.cards.isEmpty || !delta.removedCardIds.isEmpty || !delta.chats.isEmpty || !delta.removedChatIds.isEmpty
    }

    private static func merge<Value>(
        _ current: [Value],
        changed: [Value],
        removed: Set<String>,
        id: (Value) -> String
    ) -> [Value] {
        let replacements = Dictionary(uniqueKeysWithValues: changed.map { (id($0), $0) })
        var consumed: Set<String> = []
        var next = current.compactMap { value -> Value? in
            let valueID = id(value)
            guard !removed.contains(valueID) else { return nil }
            guard let replacement = replacements[valueID] else { return value }
            consumed.insert(valueID)
            return replacement
        }
        next.append(contentsOf: changed.filter { !removed.contains(id($0)) && !consumed.contains(id($0)) })
        return next
    }
}
