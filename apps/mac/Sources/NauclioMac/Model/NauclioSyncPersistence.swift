import NauclioAPI
import Foundation

struct NauclioOutboxEntry: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case createCard, createChat, sendMessage }

    var id: String { commandID }
    let commandID: String
    let clientID: String
    var endpointID: String
    let kind: Kind
    let request: Data
    let optimisticID: String
    var serverID: String? = nil
    var attempts: Int
    var lastError: String? = nil
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case commandID, clientID, endpointID, daemonID, kind, request, optimisticID, serverID, attempts, lastError, createdAt
    }

    init(
        commandID: String,
        clientID: String,
        endpointID: String,
        kind: Kind,
        request: Data,
        optimisticID: String,
        serverID: String? = nil,
        attempts: Int,
        lastError: String? = nil,
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
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        commandID = try values.decode(String.self, forKey: .commandID)
        clientID = try values.decode(String.self, forKey: .clientID)
        endpointID = try values.decodeIfPresent(String.self, forKey: .endpointID)
            ?? values.decode(String.self, forKey: .daemonID)
        kind = try values.decode(Kind.self, forKey: .kind)
        request = try values.decode(Data.self, forKey: .request)
        optimisticID = try values.decode(String.self, forKey: .optimisticID)
        serverID = try values.decodeIfPresent(String.self, forKey: .serverID)
        attempts = try values.decode(Int.self, forKey: .attempts)
        lastError = try values.decodeIfPresent(String.self, forKey: .lastError)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
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
        try values.encode(createdAt, forKey: .createdAt)
    }
}

struct NauclioSyncProjection: Codable, Sendable {
    var cursor: Data?
    var snapshot: Data?

    static let empty = NauclioSyncProjection(cursor: nil, snapshot: nil)
}

struct NauclioSyncDiskState: Codable, Sendable {
    /// Gateway-scoped daemon endpoint ID -> durable metadata projection.
    /// The endpoint ID includes the gateway credential origin, so two gateways
    /// may safely expose daemons with the same daemon ID.
    var projections: [String: NauclioSyncProjection]
    /// Legacy single-daemon fields retained only for an in-place migration.
    var cursor: Data?
    var snapshot: Data?
    var outbox: [NauclioOutboxEntry]

    init(
        projections: [String: NauclioSyncProjection] = [:],
        cursor: Data? = nil,
        snapshot: Data? = nil,
        outbox: [NauclioOutboxEntry] = []
    ) {
        self.projections = projections
        self.cursor = cursor
        self.snapshot = snapshot
        self.outbox = outbox
    }

    private enum CodingKeys: String, CodingKey { case projections, cursor, snapshot, outbox }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        projections = try values.decodeIfPresent([String: NauclioSyncProjection].self, forKey: .projections) ?? [:]
        cursor = try values.decodeIfPresent(Data.self, forKey: .cursor)
        snapshot = try values.decodeIfPresent(Data.self, forKey: .snapshot)
        outbox = try values.decodeIfPresent([NauclioOutboxEntry].self, forKey: .outbox) ?? []
    }

    static let empty = NauclioSyncDiskState()
}

enum NauclioSyncProjectionCache {
    /// A directory poll is a fresh full metadata read, not a continuation of
    /// the machine's WatchSync stream. Its snapshot must therefore never keep
    /// the old stream cursor.
    static func replacingMetadata(
        in projection: NauclioSyncProjection,
        projects: [Nauclio_V1_Project],
        boards: [Nauclio_V1_Board],
        cards: [Nauclio_V1_Card],
        chats: [Nauclio_V1_Card]
    ) -> NauclioSyncProjection {
        var snapshot = projection.snapshot
            .flatMap { try? Nauclio_V1_GlobalSnapshot(serializedBytes: $0) }
            ?? Nauclio_V1_GlobalSnapshot()
        snapshot.state.projects = projects
        snapshot.state.boards = boards
        snapshot.state.cards = cards
        snapshot.state.chats = chats
        return NauclioSyncProjection(cursor: nil, snapshot: try? snapshot.serializedData())
    }
}

enum GlobalProjectionReducer {
    static func applying(
        _ delta: Nauclio_V1_GlobalDelta,
        to snapshot: Nauclio_V1_GlobalSnapshot
    ) -> Nauclio_V1_GlobalSnapshot {
        var next = snapshot
        next.state.projects = merge(
            next.state.projects,
            changed: delta.projects,
            removed: Set(delta.removedProjectIds),
            id: \Nauclio_V1_Project.id
        )
        next.state.boards = merge(
            next.state.boards,
            changed: delta.boards,
            removed: Set(delta.removedBoardIds),
            id: \Nauclio_V1_Board.id
        )
        next.state.cards = merge(
            next.state.cards,
            changed: delta.cards,
            removed: Set(delta.removedCardIds),
            id: \Nauclio_V1_Card.id
        )
        next.state.chats = merge(
            next.state.chats,
            changed: delta.chats,
            removed: Set(delta.removedChatIds),
            id: \Nauclio_V1_Card.id
        )
        next.schedules = merge(
            next.schedules,
            changed: delta.schedules,
            removed: Set(delta.removedScheduleIds),
            id: \Nauclio_V1_Schedule.id
        )
        next.scheduleRuns = merge(
            next.scheduleRuns,
            changed: delta.scheduleRuns,
            removed: Set(delta.removedScheduleRunIds),
            id: \Nauclio_V1_ScheduleRun.id
        )
        if delta.hasSettings { next.settings = delta.settings }
        return next
    }

    private static func merge<Value>(
        _ current: [Value],
        changed: [Value],
        removed: Set<String>,
        id: KeyPath<Value, String>
    ) -> [Value] {
        let replacements = Dictionary(uniqueKeysWithValues: changed.map { ($0[keyPath: id], $0) })
        var consumed: Set<String> = []
        var next = current.compactMap { value -> Value? in
            let valueID = value[keyPath: id]
            guard !removed.contains(valueID) else { return nil }
            guard let replacement = replacements[valueID] else { return value }
            consumed.insert(valueID)
            return replacement
        }
        next.append(contentsOf: changed.filter { !removed.contains($0[keyPath: id]) && !consumed.contains($0[keyPath: id]) })
        return next
    }
}

/// A small, atomic local projection store. Protobuf remains the schema and the
/// file is only a disposable native-client projection; Nauclio domain data stays
/// authoritative under NAUCLIO_HOME on the daemon.
actor NauclioSyncPersistence {
    private let fileURL: URL

    init(root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        fileURL = base.appending(path: "Nauclio", directoryHint: .isDirectory).appending(path: "sync-state.json")
    }

    nonisolated static func installationID(defaults: UserDefaults = .standard) -> String {
        if let current = defaults.string(forKey: "NauclioSyncClientID"), !current.isEmpty { return current }
        let value = "mac_\(UUID().uuidString.lowercased())"
        defaults.set(value, forKey: "NauclioSyncClientID")
        return value
    }

    func load() -> NauclioSyncDiskState {
        guard let data = try? Data(contentsOf: fileURL),
              let value = try? JSONDecoder().decode(NauclioSyncDiskState.self, from: data) else { return .empty }
        return value
    }

    func save(_ value: NauclioSyncDiskState) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
