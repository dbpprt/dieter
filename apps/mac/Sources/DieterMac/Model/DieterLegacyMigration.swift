import Foundation

/// Imports the last Nauclio-native client state once. The daemon remains the
/// source of truth; these files only prevent a rename from signing the user out
/// or throwing away client-side ordering and sync cursors.
enum DieterLegacyMigration {
    private static let migrationKey = "DieterImportedNauclioStateV1"
    private static let legacyBundleID = "com.dbpprt.nauclio.mac"

    static func run(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: migrationKey) else { return }
        migrateDefaults(into: defaults)
        migrateFiles(fileManager: fileManager)
        defaults.set(true, forKey: migrationKey)
    }

    private static func migrateDefaults(into defaults: UserDefaults) {
        guard let legacy = UserDefaults(suiteName: legacyBundleID) else { return }
        let keys = [
            "NauclioAppearance": "DieterAppearance",
            "NauclioEndpoints": "DieterEndpoints",
            "NauclioActiveEndpoint": "DieterActiveEndpoint",
            "NauclioReadChatActivity": "DieterReadChatActivity",
            "NauclioNotifications": "DieterNotifications",
            "NauclioSyncClientID": "DieterSyncClientID",
            "NauclioSidebarProjectOrder": "DieterSidebarProjectOrder",
            "NauclioSidebarCollapsedProjects": "DieterSidebarCollapsedProjects",
            "NauclioPendingAuthentication": "DieterPendingAuthentication",
        ]
        for (oldKey, newKey) in keys where defaults.object(forKey: newKey) == nil {
            if let value = legacy.object(forKey: oldKey) {
                defaults.set(value, forKey: newKey)
            }
        }
    }

    private static func migrateFiles(fileManager: FileManager) {
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return }
        copyIfNeeded(
            from: support.appending(path: "Nauclio/sync-state.json"),
            to: support.appending(path: "Dieter/sync-state.json"),
            fileManager: fileManager
        )
        copyIfNeeded(
            from: support.appending(path: "\(legacyBundleID)/gateway-sessions.json"),
            to: support.appending(path: "com.dbpprt.dieter.mac/gateway-sessions.json"),
            fileManager: fileManager
        )
    }

    private static func copyIfNeeded(from source: URL, to destination: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: source.path),
              !fileManager.fileExists(atPath: destination.path) else { return }
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.copyItem(at: source, to: destination)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            // Migration is best effort. The authoritative daemon state remains
            // available and the client can sign in again if this copy fails.
        }
    }
}
