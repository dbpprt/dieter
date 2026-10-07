import DieterShared
import Foundation
import SharedCore
import UIKit

/// Reuses the shipping Apple platform adapters without importing either shipping UI.
@MainActor
public final class ComposeHost {
    private let shared: DieterShared
    private let mobile: MobileHost
    public let controller: UIViewController

    public init(version: String) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DieterComposeSpike", isDirectory: true)
        shared = DieterShared(
            configuration: SharedConfiguration(
                stateDirectory: directory.path, clientVersion: version,
                oauthRedirectUri: "dieter-compose-ios://oauth/callback", clientIdPrefix: "compose-ios",
                includeLoopbackRoutes: false, compactTranscripts: true, screenClientName: "Compose spike",
                desktopScreens: false),
            extensions: SharedExtensions(
                rpc: CoreRpcBridge(), secureStore: CoreKeychainSecureStore(service: "com.dbpprt.dieter.compose.spike"),
                settings: CoreDefaultsSettings(defaults: .standard), http: CoreURLSessionHttp(),
                signatures: CoreCryptoKitSignatures(),
                logger: CoreOSLogger(subsystem: "com.dbpprt.dieter.compose.spike"), notifications: nil,
                controlChannels: nil,
                screenMedia: nil, clipboard: nil, screenFixture: nil))
        mobile = MobileHost(shared: shared)
        controller = mobile.controller()
        shared.start()
    }
    public func selectTab(_ index: Int) { mobile.selectTab(index: Int32(index)) }
    public func newTask() { mobile.doNewTask() }
    public func completeSignIn(url: String) { mobile.completeSignIn(url: url) }
    public func reconnect() { mobile.reconnect() }
    public func setForeground(_ active: Bool) { mobile.setForeground(active: active) }
    public func adoptFixture(url: String, token: String) { mobile.adoptFixture(url: url, token: token) }
    public func close() { mobile.close() }
}
