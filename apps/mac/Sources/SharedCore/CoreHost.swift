import CryptoKit
import DieterShared
import Foundation

/// Where the app keeps its state, and how it identifies itself to the core.
package struct CoreHostConfiguration: Sendable {
    /// Application Support, or the `--dieter-state-root` of an isolated run.
    package let root: URL
    /// The legacy app's directory: `sync-state.json`, `pending-commands.json`, `shared-kv/`.
    package var legacyDirectory: URL { root.appending(path: "Dieter", directoryHint: .isDirectory) }
    /// The core's own state (journals, caches, the client ID).
    package var stateDirectory: URL { legacyDirectory.appending(path: "core", directoryHint: .isDirectory) }
    /// Gateway session tokens, shared with the legacy format.
    package let credentialsFile: URL
    package let clientVersion: String
    package let oauthRedirectURI: String
    package let clientIDPrefix: String
    package let logSubsystem: String

    package init(
        root: URL, credentialsFile: URL, clientVersion: String, oauthRedirectURI: String,
        clientIDPrefix: String, logSubsystem: String
    ) {
        self.root = root
        self.credentialsFile = credentialsFile
        self.clientVersion = clientVersion
        self.oauthRedirectURI = oauthRedirectURI
        self.clientIDPrefix = clientIDPrefix
        self.logSubsystem = logSubsystem
    }
}

/// Screen sharing's native side: the WebRTC engine, the pasteboard, and, for
/// an isolated native fixture only, the route the core signals through.
package struct CoreHostScreens: @unchecked Sendable {
    package let media: any NativeScreenMedia
    package let clipboard: (any NativeClipboard)?
    package let fixture: (any NativeScreenFixture)?

    package init(media: any NativeScreenMedia, clipboard: (any NativeClipboard)?, fixture: (any NativeScreenFixture)? = nil) {
        self.media = media
        self.clipboard = clipboard
        self.fixture = fixture
    }
}

/// The running shared core and what the app injected into it. Build it once
/// per process; `start()` imports the legacy app's state first when needed.
package final class CoreHost: Sendable {
    package let configuration: CoreHostConfiguration
    package let shared: DieterShared
    package let client: LiveCoreClient

    /// `notificationsEnabled` is read on every post; `defaults` holds device settings.
    package init(
        configuration: CoreHostConfiguration, defaults: UserDefaults, notificationsEnabled: @escaping @Sendable () -> Bool,
        screens: CoreHostScreens? = nil
    ) throws {
        self.configuration = configuration
        try FileManager.default.createDirectory(at: configuration.stateDirectory, withIntermediateDirectories: true)
        let shared = DieterShared(
            configuration: SharedConfiguration(
                stateDirectory: configuration.stateDirectory.path(percentEncoded: false),
                clientVersion: configuration.clientVersion,
                oauthRedirectUri: configuration.oauthRedirectURI,
                clientIdPrefix: configuration.clientIDPrefix,
                legacyClientId: defaults.string(forKey: "DieterSyncClientID"),
                includeLoopbackRoutes: true,
                compactTranscripts: false,
                screenClientName: "Mac",
                desktopScreens: true),
            extensions: SharedExtensions(
                rpc: CoreRpcBridge(),
                secureStore: CoreFileSecureStore(fileURL: configuration.credentialsFile),
                settings: CoreDefaultsSettings(defaults: defaults),
                http: CoreURLSessionHttp(),
                signatures: CoreCryptoKitSignatures(),
                logger: CoreOSLogger(subsystem: configuration.logSubsystem),
                notifications: CoreUserNotifications(isEnabled: notificationsEnabled),
                controlChannels: CoreControlChannels(),
                screenMedia: screens?.media,
                clipboard: screens?.clipboard,
                screenFixture: screens?.fixture))
        self.shared = shared
        client = LiveCoreClient(shared: shared)
        legacyDefaults = NativeCallback(defaults)
    }

    private let legacyDefaults: NativeCallback<UserDefaults>

    /// Imports the legacy app's state once (it is never deleted here), then
    /// starts supervision. Cached state is observable before this returns.
    /// Returns the import summary for the log, or nil when nothing ran.
    @discardableResult
    package func start() async -> String? {
        var summary: String?
        if shared.needsLegacyImport {
            let input = MacLegacyInputs.read(
                defaults: legacyDefaults.value, legacyDirectory: configuration.legacyDirectory,
                credentialsFile: configuration.credentialsFile)
            summary = try? await shared.importLegacy(input: input)
        }
        shared.start()
        return summary
    }

    package func shutdown() async {
        try? await shared.shutdown()
    }
}

/// The legacy macOS app's raw values, read without changing them.
package enum MacLegacyInputs {
    package static func read(defaults: UserDefaults, legacyDirectory: URL, credentialsFile: URL) -> SharedAppleLegacyInput {
        let account = defaults.string(forKey: "DieterSharedKV.activeAccount")
        let daemon = defaults.string(forKey: "DieterSharedKV.activeDaemon")
        let sharedKvJson = account.flatMap { account in
            text(legacyDirectory.appending(path: "shared-kv").appending(path: sharedKvFile(account: account, daemonID: daemon ?? "")))
        }
        let terminals = (defaults.dictionary(forKey: "DieterSelectedTerminalsByTarget") as? [String: String]) ?? [:]
        let notifications = defaults.object(forKey: "DieterNotifications") as? Bool
        return SharedAppleLegacyInput(
            endpointsJson: defaultsText(defaults, "DieterEndpoints"),
            activeEndpointJson: defaultsText(defaults, "DieterActiveEndpoint"),
            tokensJson: text(credentialsFile),
            iosGateway: nil, iosToken: nil, iosPreferredMachine: nil,
            pendingCommandsJson: text(legacyDirectory.appending(path: "pending-commands.json")),
            sharedKvAccount: account, sharedKvDaemon: daemon, sharedKvJson: sharedKvJson,
            draftsJson: defaultsText(defaults, "DieterConversationDraftTexts"),
            quickTaskChoicesJson: defaultsText(defaults, "quickTask.lastChoices"),
            creationWorkspaceMode: defaults.string(forKey: "DieterConversationCreationWorkspaceMode"),
            terminalSelections: terminals,
            notificationsEnabled: notifications.map { KotlinBoolean(bool: $0) },
            isIos: false)
    }

    /// `sha256("DieterSharedKV.<account>.navigation[.<daemon>]").json`; the daemon
    /// is part of the key only for the `local` account (the core's `macSharedKvFile`).
    package static func sharedKvFile(account: String, daemonID: String) -> String {
        let key = "DieterSharedKV.\(account).navigation" + (account == "local" ? ".\(daemonID)" : "")
        return SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    /// JSON stored as Data (Codable) or as a string.
    private static func defaultsText(_ defaults: UserDefaults, _ key: String) -> String? {
        if let data = defaults.data(forKey: key) { return String(data: data, encoding: .utf8) }
        return defaults.string(forKey: key)
    }

    private static func text(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
