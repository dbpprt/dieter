import DieterShared
import Foundation

/// Where the app keeps its state, and how it identifies itself to the core.
package struct CoreHostConfiguration: Sendable {
    /// Application Support, or the `--dieter-state-root` of an isolated run.
    package let root: URL
    /// The core's own state (journals, caches, the client ID).
    package var stateDirectory: URL { root.appending(path: "Dieter/core", directoryHint: .isDirectory) }
    package let clientVersion: String
    package let logSubsystem: String

    package init(root: URL, clientVersion: String, logSubsystem: String) {
        self.root = root
        self.clientVersion = clientVersion
        self.logSubsystem = logSubsystem
    }
}

/// What differs between the apps that host the core: where gateway sessions
/// are kept, which routes and transcript window the device uses, how a shared
/// screen's host names it, and the platform services it injects.
package struct CoreHostPlatform: @unchecked Sendable {
    /// Gateway session tokens, keyed by gateway origin.
    package let secureStore: any NativeSecureStore
    /// Only a machine that can run a daemon itself tries loopback routes.
    package let includeLoopbackRoutes: Bool
    /// Phones and tablets keep a smaller transcript window than desktops.
    package let compactTranscripts: Bool
    /// The name a shared screen's host shows for this client.
    package let screenClientName: String
    /// Desktops ask for their view's size; touch devices for a coarse grid.
    package let desktopScreens: Bool
    /// The prefix of a newly generated sync client ID, e.g. `mac` or `ios`.
    package let clientIDPrefix: String
    package let oauthRedirectURI: String
    package let notifications: (any NativeNotifications)?
    /// The pasteboard screen sharing syncs; nil leaves clipboard sync off.
    package let clipboard: (any NativeClipboard)?

    package init(
        secureStore: any NativeSecureStore, includeLoopbackRoutes: Bool, compactTranscripts: Bool,
        screenClientName: String, desktopScreens: Bool, clientIDPrefix: String, oauthRedirectURI: String,
        notifications: (any NativeNotifications)?, clipboard: (any NativeClipboard)?
    ) {
        self.secureStore = secureStore
        self.includeLoopbackRoutes = includeLoopbackRoutes
        self.compactTranscripts = compactTranscripts
        self.screenClientName = screenClientName
        self.desktopScreens = desktopScreens
        self.clientIDPrefix = clientIDPrefix
        self.oauthRedirectURI = oauthRedirectURI
        self.notifications = notifications
        self.clipboard = clipboard
    }

    /// The scheme both apps register for the gateway's native redirect.
    package static let nativeOAuthScheme = "dieter-mac"

    /// The gateway's registered native redirect, shared by the Mac and iOS apps.
    package static let nativeOAuthRedirectURI = "\(nativeOAuthScheme)://oauth/callback"

    /// Whether `url` is the gateway's sign-in callback.
    package static func isNativeOAuthCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == nativeOAuthScheme && url.host?.lowercased() == "oauth"
    }

    /// The Mac: sessions in a private file, loopback routes to its own daemon,
    /// full transcripts, and desktop-sized screens. `notificationsEnabled` is
    /// read on every post.
    package static func mac(
        credentialsFile: URL, notificationsEnabled: @escaping @Sendable () -> Bool,
        clipboard: (any NativeClipboard)? = nil
    ) -> CoreHostPlatform {
        CoreHostPlatform(
            secureStore: CoreFileSecureStore(fileURL: credentialsFile), includeLoopbackRoutes: true,
            compactTranscripts: false, screenClientName: "Mac", desktopScreens: true, clientIDPrefix: "mac",
            oauthRedirectURI: nativeOAuthRedirectURI,
            notifications: CoreUserNotifications(isEnabled: notificationsEnabled),
            clipboard: clipboard)
    }

    /// iPhone and iPad: sessions in the Keychain, remote routes only, compact
    /// transcripts, and touch screens. `screenClientName` is "iPhone" or "iPad".
    package static func iOS(
        screenClientName: String, notificationsEnabled: @escaping @Sendable () -> Bool,
        secureStore: any NativeSecureStore = CoreKeychainSecureStore(),
        clipboard: (any NativeClipboard)? = nil
    ) -> CoreHostPlatform {
        CoreHostPlatform(
            secureStore: secureStore, includeLoopbackRoutes: false, compactTranscripts: true,
            screenClientName: screenClientName, desktopScreens: false, clientIDPrefix: "ios",
            oauthRedirectURI: nativeOAuthRedirectURI,
            notifications: CoreUserNotifications(isEnabled: notificationsEnabled),
            clipboard: clipboard)
    }
}

/// Screen sharing's native side: the WebRTC engine and, for an isolated
/// native fixture only, the route the core signals through.
package struct CoreHostScreens: @unchecked Sendable {
    package let media: any NativeScreenMedia
    package let fixture: (any NativeScreenFixture)?

    package init(media: any NativeScreenMedia, fixture: (any NativeScreenFixture)? = nil) {
        self.media = media
        self.fixture = fixture
    }
}

/// The running shared core and what the app injected into it. Build it once
/// per process.
package final class CoreHost: Sendable {
    package let configuration: CoreHostConfiguration
    package let platform: CoreHostPlatform
    package let shared: DieterShared
    package let client: LiveCoreClient

    /// `defaults` holds device settings.
    package init(
        configuration: CoreHostConfiguration, platform: CoreHostPlatform, defaults: UserDefaults,
        screens: CoreHostScreens? = nil
    ) throws {
        self.configuration = configuration
        self.platform = platform
        try FileManager.default.createDirectory(at: configuration.stateDirectory, withIntermediateDirectories: true)
        let shared = DieterShared(
            configuration: SharedConfiguration(
                stateDirectory: configuration.stateDirectory.path(percentEncoded: false),
                clientVersion: configuration.clientVersion,
                oauthRedirectUri: platform.oauthRedirectURI,
                clientIdPrefix: platform.clientIDPrefix,
                includeLoopbackRoutes: platform.includeLoopbackRoutes,
                compactTranscripts: platform.compactTranscripts,
                screenClientName: platform.screenClientName,
                desktopScreens: platform.desktopScreens),
            extensions: SharedExtensions(
                rpc: CoreRpcBridge(),
                secureStore: platform.secureStore,
                settings: CoreDefaultsSettings(defaults: defaults),
                http: CoreURLSessionHttp(),
                signatures: CoreCryptoKitSignatures(),
                logger: CoreOSLogger(subsystem: configuration.logSubsystem),
                notifications: platform.notifications,
                controlChannels: CoreControlChannels(),
                screenMedia: screens?.media,
                clipboard: platform.clipboard,
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
