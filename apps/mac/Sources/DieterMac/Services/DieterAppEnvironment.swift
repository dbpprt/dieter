import Foundation

/// Composition inputs. Feature models receive narrower capabilities from here.
@MainActor
struct DieterAppEnvironment {
    let arguments: [String]
    let defaults: UserDefaults
    let storageRoot: URL?
    let credentials: DieterCredentialFileStore
    let clock: ClientClock
    let clients: DieterClientFactory

    init(
        arguments: [String], defaults: UserDefaults, storageRoot: URL?,
        credentials: DieterCredentialFileStore? = nil, clock: ClientClock = .live,
        clients: DieterClientFactory = .live
    ) {
        self.arguments = arguments; self.defaults = defaults; self.storageRoot = storageRoot
        self.credentials =
            credentials
            ?? DieterCredentialFileStore(
                fileURL: storageRoot?
                    .appending(path: "gateway-sessions.json") ?? DieterCredentialFileStore.defaultFileURL())
        self.clock = clock; self.clients = clients
    }

    static func live(arguments: [String] = ProcessInfo.processInfo.arguments) -> Self {
        .init(
            arguments: arguments, defaults: DieterAppearance.applicationDefaults(arguments: arguments),
            storageRoot: DieterSyncPersistence.overrideRoot(arguments: arguments))
    }

    static func testing(defaults: UserDefaults? = nil) -> Self {
        .init(
            arguments: [], defaults: defaults ?? UserDefaults(suiteName: "DieterTests.\(UUID().uuidString)")!,
            storageRoot: FileManager.default.temporaryDirectory.appending(path: "dieter-client-\(UUID().uuidString)"))
    }
}
