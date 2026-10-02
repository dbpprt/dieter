import DieterShared
import Foundation

/// Where the app keeps its state, and how it identifies itself to the core.
package struct CoreHostConfiguration: Sendable {
    /// Application Support, or the `--dieter-state-root` of an isolated run.
    package let root: URL
    /// The core's own state (journals, caches, the client ID).
    package var stateDirectory: URL { root.appending(path: "Dieter/core", directoryHint: .isDirectory) }
    /// Gateway session tokens, keyed by gateway origin.
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
/// per process.
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
    }

    /// Starts supervision. Cached state is observable before this.
    package func start() {
        shared.start()
    }

    package func shutdown() async {
        try? await shared.shutdown()
    }
}
