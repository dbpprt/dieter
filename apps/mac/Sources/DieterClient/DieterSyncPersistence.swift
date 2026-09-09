import DieterCore
import DieterAPI
import Foundation
import OSLog

private let syncPersistenceLog = OSLog(
    subsystem: "com.dbpprt.dieter.mac",
    category: "SyncPersistence"
)

/// A small, atomic local projection store. Protobuf remains the schema and the
/// file is only a disposable native-client projection; Dieter domain data stays
/// authoritative under DIETER_HOME on the daemon.
package actor DieterSyncPersistence {
    package typealias Writer = @Sendable (DieterSyncDiskState, URL) throws -> Int

    package struct Metrics: Equatable, Sendable {
        package let acceptedSaveCount: Int
        package let writeCount: Int
        package let logicalBytesWritten: Int
    }

    package nonisolated let fileURL: URL
    package nonisolated var outboxJournalURL: URL {
        fileURL.deletingLastPathComponent().appending(path: "pending-commands.json")
    }
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

    package init(
        root: URL? = nil,
        writer: Writer? = nil,
        checkpointDelayNanoseconds: UInt64 = 2_000_000_000
    ) {
        let base =
            root ?? Self.overrideRoot() ?? FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
        fileURL = base.appending(path: "Dieter", directoryHint: .isDirectory).appending(path: "sync-state.json")
        self.writer = writer ?? Self.write
        self.checkpointDelayNanoseconds = checkpointDelayNanoseconds
    }

    /// Smoke runs point the projection at a throwaway directory so isolated
    /// fixtures neither read stale state nor write into the real projection.
    package nonisolated static func overrideRoot(arguments: [String] = ProcessInfo.processInfo.arguments) -> URL? {
        guard let index = arguments.firstIndex(of: "--dieter-state-root"),
            arguments.indices.contains(index + 1)
        else { return nil }
        return URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
    }

    package nonisolated static func installationID(defaults: UserDefaults = .standard) -> String {
        if let current = defaults.string(forKey: "DieterSyncClientID"), !current.isEmpty { return current }
        let value = "mac_\(UUID().uuidString.lowercased())"
        defaults.set(value, forKey: "DieterSyncClientID")
        return value
    }

    package func load() -> DieterSyncDiskState {
        guard let data = try? Data(contentsOf: fileURL),
            let value = try? JSONDecoder().decode(DieterSyncDiskState.self, from: data)
        else { return .empty }
        return value
    }

    /// Replaces any not-yet-started write with the newest snapshot. Callers
    /// that only need eventual persistence avoid waiting for JSON encoding and
    /// disk I/O on the main actor.
    package func scheduleSave(_ value: DieterSyncDiskState) {
        _ = enqueue(.init(diskState: value))
        startWriterIfNeeded()
    }

    /// Debounces disposable projection checkpoints while always retaining the
    /// newest revision. Durability-sensitive callers use `saveCheckpoint`.
    package func scheduleCheckpoint(_ value: DieterSyncCheckpoint) {
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
    package func save(_ value: DieterSyncDiskState) async throws {
        try await saveCheckpoint(.init(diskState: value))
    }

    /// Persists this checkpoint (or a newer checkpoint that supersedes it)
    /// before returning.
    package func saveCheckpoint(_ value: DieterSyncCheckpoint) async throws {
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

    package func metrics() -> Metrics {
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
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
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
