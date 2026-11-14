import AppKit
import DieterCore
import DieterIdentity
import DieterMacTestSupport
import DieterPlatform
import DieterTransport
import Foundation
import Synchronization
import Testing
@testable import DieterMacKit

/// What the disposable native screen fixture (`tools/fixtures/screens`)
/// writes once it listens: a loopback daemon API, its signing certificate
/// (PEM), ICE configuration, and a bearer token.
struct ScreenFixtureConnection: Decodable {
    var url: String
    var certificate: Data
    var rtc: Data
    var clipboardName: String?
    var token: String

    var daemonPublicKey: Data { screenFixtureDaemonPublicKey(certificate) }
}

/// A fixture daemon's Ed25519 key as a device roster lists it: the DER
/// SubjectPublicKeyInfo of its PEM signing certificate.
func screenFixtureDaemonPublicKey(_ certificatePEM: Data) -> Data {
    let body = String(decoding: certificatePEM, as: UTF8.self)
        .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
        .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
        .components(separatedBy: .whitespacesAndNewlines).joined()
    return Data(base64Encoded: body).flatMap { DaemonKeyPinning.subjectPublicKeyInfo(certificateDER: $0) } ?? Data()
}

/// The fixture's signaling routes as the core opens them; tests count the
/// openings and make the next ones fail as a sleeping laptop's network would.
final class ScreenFixtureRoutes: NSObject, NativeScreenFixture, @unchecked Sendable {
    private let fixture: ScreenFixtureConnection
    private let state = Mutex((openings: 0, unavailable: 0))

    init(_ fixture: ScreenFixtureConnection) {
        self.fixture = fixture
    }

    var openings: Int { state.withLock { $0.openings } }

    func failNext(_ count: Int) { state.withLock { $0.unavailable = count } }

    func open() -> NativeScreenFixtureRoute? {
        let available = state.withLock { state -> Bool in
            state.openings += 1
            guard state.unavailable == 0 else {
                state.unavailable -= 1
                return false
            }
            return true
        }
        guard available else { return nil }
        return NativeScreenFixtureRoute(
            url: fixture.url, token: fixture.token, daemonPublicKey: fixture.daemonPublicKey,
            rtc: fixture.rtc, label: "Fixture loopback")
    }
}

/// An isolated shared core (temporary state, an own defaults suite, never
/// signed in) whose screens signal through the fixture and render through the
/// Mac's WebRTC engine. It never touches the operator's app, daemon, or state.
@MainActor final class ScreenFixtureCore {
    let media = CoreScreenMedia.mac()
    let routes: ScreenFixtureRoutes
    let host: CoreHost
    private let root: URL
    private let suite: String

    init(_ fixture: ScreenFixtureConnection, clipboard: CoreScreenClipboard) throws {
        routes = ScreenFixtureRoutes(fixture)
        root = FileManager.default.temporaryDirectory.appending(path: "dieter-screen-core-\(UUID().uuidString)")
        suite = "ScreenFixtureCore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        host = try CoreHost(
            configuration: CoreHostConfiguration(
                root: root, clientVersion: DieterRelease.current,
                logSubsystem: DistributionIdentity.macBundleID + ".tests"),
            platform: .mac(
                credentialsFile: root.appending(path: "gateway-sessions.json"),
                deviceKeyFile: root.appending(path: "device-key.json"), notificationsEnabled: { false },
                clipboard: clipboard),
            defaults: defaults, screens: CoreHostScreens(media: media, fixture: routes))
    }

    func controller() -> RemoteDesktopController { RemoteDesktopController(core: host.client, media: media) }

    func close() async {
        await host.shutdown()
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}

/// Starts the fixture with `arguments` and waits for its connection file.
@MainActor func startScreenFixture(
    executable: String, arguments: [String], environment: [String: String], output: URL, log: FileHandle
) async throws -> (Process, ScreenFixtureConnection) {
    let ready = output.appending(path: "ready.json")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments + ["--ready", ready.path]
    process.environment = environment
    process.standardOutput = log
    process.standardError = log
    try process.run()
    try await screenWait("fixture readiness", timeout: 10) {
        FileManager.default.fileExists(atPath: ready.path) || !process.isRunning
    }
    return (process, try JSONDecoder().decode(ScreenFixtureConnection.self, from: Data(contentsOf: ready)))
}

/// A direct client to the fixture for host-side assertions the app never makes.
func screenFixtureRPC(_ fixture: ScreenFixtureConnection) throws -> FixtureRPCClient {
    try FixtureRPCClient(origin: fixture.url, token: fixture.token)
}

@MainActor func screenWait(_ label: String, timeout: Double, condition: () -> Bool) async throws {
    FileHandle.standardError.write(Data("Screen test waiting: \(label)\n".utf8))
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try await Task.sleep(for: .milliseconds(25))
    }
    FileHandle.standardError.write(Data("Screen test completed: \(label) = \(condition())\n".utf8))
    #expect(condition(), "Timed out: \(label)")
    if !condition() { throw NSError(domain: "ScreenE2E", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
}
