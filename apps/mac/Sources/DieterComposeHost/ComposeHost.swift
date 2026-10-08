import DieterShared
import Foundation
import SharedCore
import UIKit
import Observation
import Metal

/// Reuses the shipping Apple platform adapters without importing either shipping UI.
@MainActor
@Observable
public final class ComposeHost {
    @ObservationIgnored private let shared: DieterShared
    @ObservationIgnored private let mobile: MobileHost
    public let controller: UIViewController
    public private(set) var selectedTab = 0
    public private(set) var chromeVisible = true
    public private(set) var appearance = "system"
    public private(set) var palette = "monochrome"
    @ObservationIgnored private var navigationObservation: MobileObservation?

    public init(version: String) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DieterComposeSpike", isDirectory: true)
        let media = CoreScreenMedia {
            MTLCreateSystemDefaultDevice() == nil ? "Metal is unavailable on this device." : nil
        }
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
                controlChannels: CoreControlChannels(),
                screenMedia: media, clipboard: CoreUIPasteboardClipboard(), screenFixture: nil))
        mobile = MobileHost(shared: shared, nativeViews: ComposeNativeViews(media: media))
        controller = mobile.controller()
        navigationObservation = mobile.observeNavigation(
            observer: ComposeNavigation { [weak self] index, visible, appearance, palette in
                self?.selectedTab = index; self?.chromeVisible = visible; self?.appearance = appearance;
                self?.palette = palette
            })
        shared.start()
    }
    public func selectTab(_ index: Int) { mobile.selectTab(index: Int32(index)) }
    public func newTask() { mobile.doNewTask() }
    public func completeSignIn(url: String) { mobile.completeSignIn(url: url) }
    public func reconnect() { mobile.reconnect() }
    public func setForeground(_ active: Bool) { mobile.setForeground(active: active) }
    public func adoptFixture(url: String, token: String) { mobile.adoptFixture(url: url, token: token) }
    public func close() { navigationObservation?.close(); mobile.close() }
}

private final class ComposeNavigation: NSObject, MobileNavigationObserver, Sendable {
    private let update: @MainActor @Sendable (Int, Bool, String, String) -> Void
    init(_ update: @escaping @MainActor @Sendable (Int, Bool, String, String) -> Void) { self.update = update }
    func changed(index: Int32, chromeVisible: Bool, appearance: String, palette: String) {
        MainActor.assumeIsolated { update(Int(index), chromeVisible, appearance, palette) }
    }
}
