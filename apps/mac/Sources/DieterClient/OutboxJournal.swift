import DieterCore
import Foundation

/// Serial, atomic transactions over pending user commands. Projection checkpoints
/// never write this file, and failed transactions never become deliverable.
package actor OutboxJournal {
    package typealias Writer = @Sendable (Data, URL) throws -> Void
    package struct Snapshot: Codable, Sendable {
        package var version = 1
        package var revision: UInt64 = 0
        package var entries: [DieterOutboxEntry] = []
    }
    private struct Legacy: Decodable { var outbox: [DieterOutboxEntry] }
    private let url: URL
    private let legacyURL: URL
    private let writer: Writer
    private var state: Snapshot?
    package static let entryLimit = 1_000
    package static let byteLimit = 64 * 1_024 * 1_024

    package init(url: URL, legacyURL: URL, writer: Writer? = nil) {
        self.url = url; self.legacyURL = legacyURL
        self.writer = writer ?? Self.write
    }

    package func load() throws -> Snapshot {
        if let state { return state }
        if FileManager.default.fileExists(atPath: url.path) {
            let loaded = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
            guard loaded.version == 1 else { throw OutboxStorageError.unsupportedVersion }
            state = loaded
            return loaded
        }
        var migrated = Snapshot()
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            // Decode only the commands: corrupt disposable protobuf projections
            // must not make a recoverable outbox disappear.
            migrated.entries = try JSONDecoder().decode(Legacy.self, from: Data(contentsOf: legacyURL)).outbox
        }
        try persist(migrated)
        state = migrated
        return migrated
    }

    package func transaction<Result: Sendable>(
        _ operation: @Sendable (inout [DieterOutboxEntry]) throws -> Result
    ) throws -> (Snapshot, Result) {
        var next = try load()
        let result = try operation(&next.entries)
        if next.entries != state?.entries {
            // Existing journals above today's admission limit must still drain.
            // Only growth is rejected until they fall back within the budget.
            guard next.entries.count <= max(Self.entryLimit, state?.entries.count ?? 0) else {
                throw OutboxStorageError.full
            }
            next.revision &+= 1
            try persist(next)
            state = next
        }
        return (next, result)
    }

    private func persist(_ snapshot: Snapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= Self.byteLimit else { throw OutboxStorageError.full }
        try writer(data, url)
    }

    nonisolated private static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

package enum OutboxStorageError: LocalizedError {
    case unsupportedVersion, full
    package var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            "Pending messages were saved by a newer Dieter version. Update Dieter to recover them."
        case .full:
            "Pending messages have reached the local storage limit. Send or discard queued items before adding more."
        }
    }
}
