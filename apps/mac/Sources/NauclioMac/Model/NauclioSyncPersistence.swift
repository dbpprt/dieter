import NauclioAPI
import Foundation

struct NauclioOutboxEntry: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case createCard, createChat, sendMessage }

    var id: String { commandID }
    let commandID: String
    let clientID: String
    let daemonID: String
    let kind: Kind
    let request: Data
    let optimisticID: String
    var serverID: String? = nil
    var attempts: Int
    var lastError: String? = nil
    let createdAt: Date
}

struct NauclioSyncDiskState: Codable, Sendable {
    var cursor: Data?
    var snapshot: Data?
    var outbox: [NauclioOutboxEntry]

    static let empty = NauclioSyncDiskState(cursor: nil, snapshot: nil, outbox: [])
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
