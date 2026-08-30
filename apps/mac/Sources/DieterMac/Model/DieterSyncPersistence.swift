import DieterAPI
import Foundation
import OSLog

private let syncPersistenceLog = OSLog(
    subsystem: "com.dbpprt.dieter.mac",
    category: "SyncPersistence"
)

struct DieterOutboxEntry: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case createCard, createChat, sendMessage }
    enum State: String, Codable, Sendable { case queued, retrying, failed }

    var id: String { commandID }
    let commandID: String
    let clientID: String
    var endpointID: String
    let kind: Kind
    var request: Data
    let optimisticID: String
    var serverID: String? = nil
    var attempts: Int
    var lastError: String? = nil
    var state: State = .queued
    var nextAttemptAt: Date? = nil
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case commandID, clientID, endpointID, daemonID, kind, request, optimisticID, serverID, attempts, lastError, state, nextAttemptAt, createdAt
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
        state = try values.decodeIfPresent(State.self, forKey: .state) ?? .queued
        nextAttemptAt = try values.decodeIfPresent(Date.self, forKey: .nextAttemptAt)
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
        try values.encode(state, forKey: .state)
        try values.encodeIfPresent(nextAttemptAt, forKey: .nextAttemptAt)
        try values.encode(createdAt, forKey: .createdAt)
    }
}

struct DieterSyncProjection: Codable, Sendable {
    var cursor: Data?
    var snapshot: Data?
    /// Wall-clock time of the most recent authoritative WatchSync frame.
    /// Persisting this separately from the snapshot lets the UI report the
    /// age of a cursor-only heartbeat after relaunching.
    var refreshedAt: Date? = nil

    static let empty = DieterSyncProjection(cursor: nil, snapshot: nil)
}

struct DieterSyncDiskState: Codable, Sendable {
    /// Gateway-scoped daemon endpoint ID -> durable metadata projection.
    /// The endpoint ID includes the gateway credential origin, so two gateways
    /// may safely expose daemons with the same daemon ID.
    var projections: [String: DieterSyncProjection]
    /// Legacy single-daemon fields retained only for an in-place migration.
    var cursor: Data?
    var snapshot: Data?
    /// Endpoint ID -> card ID -> the wall-clock time at which the native
    /// client last received authoritative conversation data.
    var conversationRefreshedAt: [String: [String: Date]]
    var outbox: [DieterOutboxEntry]

    init(
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

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        projections = try values.decodeIfPresent([String: DieterSyncProjection].self, forKey: .projections) ?? [:]
        cursor = try values.decodeIfPresent(Data.self, forKey: .cursor)
        snapshot = try values.decodeIfPresent(Data.self, forKey: .snapshot)
        conversationRefreshedAt = try values.decodeIfPresent(
            [String: [String: Date]].self,
            forKey: .conversationRefreshedAt
        ) ?? [:]
        outbox = try values.decodeIfPresent([DieterOutboxEntry].self, forKey: .outbox) ?? []
    }

    mutating func clearProjections() {
        projections.removeAll()
        cursor = nil
        snapshot = nil
        conversationRefreshedAt.removeAll()
    }

    static let empty = DieterSyncDiskState()
}

/// A persistence input that keeps the active protobuf projection in its
/// in-memory form until it reaches the persistence executor. This prevents the
/// main actor from serializing a multi-megabyte snapshot for every streamed
/// conversation update.
struct DieterSyncCheckpoint: Sendable {
    var diskState: DieterSyncDiskState
    let activeEndpointID: String
    let activeSnapshot: Dieter_V1_GlobalSnapshot?

    init(
        diskState: DieterSyncDiskState,
        activeEndpointID: String = "",
        activeSnapshot: Dieter_V1_GlobalSnapshot? = nil
    ) {
        self.diskState = diskState
        self.activeEndpointID = activeEndpointID
        self.activeSnapshot = activeSnapshot
    }

    func materialized() throws -> DieterSyncDiskState {
        guard !activeEndpointID.isEmpty, let activeSnapshot else { return diskState }
        var value = diskState
        var projection = value.projections[activeEndpointID] ?? .empty
        projection.snapshot = try activeSnapshot.serializedData()
        value.projections[activeEndpointID] = projection
        return value
    }
}

enum DieterSyncProjectionCache {
    /// A directory poll is a fresh full metadata read, not a continuation of
    /// the machine's WatchSync stream. Its snapshot must therefore never keep
    /// the old stream cursor.
    static func replacingMetadata(
        in projection: DieterSyncProjection,
        projects: [Dieter_V1_Project],
        boards: [Dieter_V1_Board],
        cards: [Dieter_V1_Card],
        chats: [Dieter_V1_Card]
    ) -> DieterSyncProjection {
        var snapshot = projection.snapshot
            .flatMap { try? Dieter_V1_GlobalSnapshot(serializedBytes: $0) }
            ?? Dieter_V1_GlobalSnapshot()
        snapshot.state.projects = projects
        snapshot.state.boards = boards
        snapshot.state.cards = cards
        snapshot.state.chats = chats
        return DieterSyncProjection(
            cursor: nil,
            snapshot: try? snapshot.serializedData(),
            refreshedAt: projection.refreshedAt
        )
    }

    static func cachingConversation(
        _ conversation: Dieter_V1_ConversationSnapshot,
        in projection: DieterSyncProjection,
        limit: Int
    ) -> (projection: DieterSyncProjection, retainedCardIDs: Set<String>) {
        let cardID = conversation.detail.card.id
        var snapshot = projection.snapshot
            .flatMap { try? Dieter_V1_GlobalSnapshot(serializedBytes: $0) }
            ?? Dieter_V1_GlobalSnapshot()
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

enum GlobalProjectionReducer {
    static func changesProjection(_ delta: Dieter_V1_GlobalDelta) -> Bool {
        !delta.projects.isEmpty || !delta.removedProjectIds.isEmpty ||
            !delta.boards.isEmpty || !delta.removedBoardIds.isEmpty ||
            !delta.cards.isEmpty || !delta.removedCardIds.isEmpty ||
            !delta.chats.isEmpty || !delta.removedChatIds.isEmpty ||
            !delta.schedules.isEmpty || !delta.removedScheduleIds.isEmpty ||
            !delta.scheduleRuns.isEmpty || !delta.removedScheduleRunIds.isEmpty ||
            delta.hasSettings ||
            !delta.conversations.isEmpty || !delta.removedConversationIds.isEmpty
    }

    static func applying(
        _ delta: Dieter_V1_GlobalDelta,
        to snapshot: Dieter_V1_GlobalSnapshot
    ) -> Dieter_V1_GlobalSnapshot {
        var next = snapshot
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
        if !delta.schedules.isEmpty || !delta.removedScheduleIds.isEmpty {
            next.schedules = merge(
                next.schedules,
                changed: delta.schedules,
                removed: Set(delta.removedScheduleIds),
                id: { $0.id }
            )
        }
        if !delta.scheduleRuns.isEmpty || !delta.removedScheduleRunIds.isEmpty {
            next.scheduleRuns = merge(
                next.scheduleRuns,
                changed: delta.scheduleRuns,
                removed: Set(delta.removedScheduleRunIds),
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

    static func changesWorkspace(_ delta: Dieter_V1_GlobalDelta) -> Bool {
        !delta.projects.isEmpty || !delta.removedProjectIds.isEmpty ||
            !delta.boards.isEmpty || !delta.removedBoardIds.isEmpty ||
            !delta.cards.isEmpty || !delta.removedCardIds.isEmpty ||
            !delta.chats.isEmpty || !delta.removedChatIds.isEmpty ||
            !delta.schedules.isEmpty || !delta.removedScheduleIds.isEmpty ||
            !delta.scheduleRuns.isEmpty || !delta.removedScheduleRunIds.isEmpty ||
            delta.hasSettings
    }

    static func changesConversationDirectory(_ delta: Dieter_V1_GlobalDelta) -> Bool {
        !delta.cards.isEmpty || !delta.removedCardIds.isEmpty ||
            !delta.chats.isEmpty || !delta.removedChatIds.isEmpty
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

/// A small, atomic local projection store. Protobuf remains the schema and the
/// file is only a disposable native-client projection; Dieter domain data stays
/// authoritative under DIETER_HOME on the daemon.
actor DieterSyncPersistence {
    typealias Writer = @Sendable (DieterSyncDiskState, URL) throws -> Int

    struct Metrics: Equatable, Sendable {
        let acceptedSaveCount: Int
        let writeCount: Int
        let logicalBytesWritten: Int
    }

    private let fileURL: URL
    private let writer: Writer
    private let checkpointDelayNanoseconds: UInt64
    private var pending: (revision: UInt64, value: DieterSyncCheckpoint)?
    private var writerTask: Task<Void, Never>?
    private var checkpointTask: Task<Void, Never>?
    private var waiters: [UInt64: [CheckedContinuation<Void, Error>]] = [:]
    private var nextRevision: UInt64 = 0
    private var completedRevision: UInt64 = 0
    private var acceptedSaveCount = 0
    private var writeCount = 0
    private var logicalBytesWritten = 0

    init(
        root: URL? = nil,
        writer: Writer? = nil,
        checkpointDelayNanoseconds: UInt64 = 2_000_000_000
    ) {
        let base = root ?? Self.overrideRoot() ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        fileURL = base.appending(path: "Dieter", directoryHint: .isDirectory).appending(path: "sync-state.json")
        self.writer = writer ?? Self.write
        self.checkpointDelayNanoseconds = checkpointDelayNanoseconds
    }

    /// Smoke runs point the projection at a throwaway directory so isolated
    /// fixtures neither read stale state nor write into the real projection.
    nonisolated static func overrideRoot(arguments: [String] = ProcessInfo.processInfo.arguments) -> URL? {
        guard let index = arguments.firstIndex(of: "--dieter-state-root"),
              arguments.indices.contains(index + 1) else { return nil }
        return URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
    }

    nonisolated static func installationID(defaults: UserDefaults = .standard) -> String {
        if let current = defaults.string(forKey: "DieterSyncClientID"), !current.isEmpty { return current }
        let value = "mac_\(UUID().uuidString.lowercased())"
        defaults.set(value, forKey: "DieterSyncClientID")
        return value
    }

    func load() -> DieterSyncDiskState {
        guard let data = try? Data(contentsOf: fileURL),
              let value = try? JSONDecoder().decode(DieterSyncDiskState.self, from: data) else { return .empty }
        return value
    }

    /// Replaces any not-yet-started write with the newest snapshot. Callers
    /// that only need eventual persistence avoid waiting for JSON encoding and
    /// disk I/O on the main actor.
    func scheduleSave(_ value: DieterSyncDiskState) {
        _ = enqueue(.init(diskState: value))
        startWriterIfNeeded()
    }

    /// Debounces disposable projection checkpoints while always retaining the
    /// newest revision. Durability-sensitive callers use `saveCheckpoint`.
    func scheduleCheckpoint(_ value: DieterSyncCheckpoint) {
        _ = enqueue(value)
        checkpointTask?.cancel()
        let delay = checkpointDelayNanoseconds
        checkpointTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.beginScheduledCheckpoint()
        }
    }

    /// Persists this state (or a newer state that supersedes it) before
    /// returning. Used for durability boundaries such as outbox changes.
    func save(_ value: DieterSyncDiskState) async throws {
        try await saveCheckpoint(.init(diskState: value))
    }

    /// Persists this checkpoint (or a newer checkpoint that supersedes it)
    /// before returning.
    func saveCheckpoint(_ value: DieterSyncCheckpoint) async throws {
        checkpointTask?.cancel()
        checkpointTask = nil
        let revision = enqueue(value)
        startWriterIfNeeded()
        try await withCheckedThrowingContinuation { continuation in
            if completedRevision >= revision {
                continuation.resume()
            } else {
                waiters[revision, default: []].append(continuation)
            }
        }
    }

    func metrics() -> Metrics {
        Metrics(
            acceptedSaveCount: acceptedSaveCount,
            writeCount: writeCount,
            logicalBytesWritten: logicalBytesWritten
        )
    }

    private func enqueue(_ value: DieterSyncCheckpoint) -> UInt64 {
        nextRevision &+= 1
        acceptedSaveCount += 1
        pending = (nextRevision, value)
        return nextRevision
    }

    private func beginScheduledCheckpoint() {
        checkpointTask = nil
        startWriterIfNeeded()
    }

    private func startWriterIfNeeded() {
        guard writerTask == nil else { return }
        writerTask = Task { await drainWrites() }
    }

    private func drainWrites() async {
        while let write = pending {
            pending = nil
            do {
                let writer = writer
                let fileURL = fileURL
                let bytes = try await Task.detached(priority: .utility) {
                    try writer(write.value.materialized(), fileURL)
                }.value
                writeCount += 1
                logicalBytesWritten += bytes
                completedRevision = max(completedRevision, write.revision)
                resumeWaiters(through: write.revision, error: nil)
            } catch {
                completedRevision = max(completedRevision, write.revision)
                resumeWaiters(through: write.revision, error: error)
                Logger(subsystem: "com.dbpprt.dieter.mac", category: "SyncPersistence")
                    .error("Failed to persist sync projection: \(error.localizedDescription, privacy: .public)")
            }
        }
        writerTask = nil
    }

    private func resumeWaiters(through revision: UInt64, error: Error?) {
        let completed = waiters.keys.filter { $0 <= revision }
        for key in completed {
            let continuations = waiters.removeValue(forKey: key) ?? []
            for continuation in continuations {
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    nonisolated private static func write(_ value: DieterSyncDiskState, to fileURL: URL) throws -> Int {
        os_signpost(.begin, log: syncPersistenceLog, name: "Encode and write sync state")
        defer { os_signpost(.end, log: syncPersistenceLog, name: "Encode and write sync state") }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        return data.count
    }
}
