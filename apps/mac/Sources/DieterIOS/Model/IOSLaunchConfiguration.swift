#if os(iOS)
    import DieterShared
    import Foundation
    import UIKit

    /// Where this launch keeps its state and what it was asked to do. A
    /// release build always uses Application Support and the standard
    /// defaults; a DEBUG build started by the isolated UI tests uses a
    /// per-launch temporary root and defaults suite and adopts the test
    /// gateway's session.
    struct IOSLaunchConfiguration {
        /// A gateway session handed in by the launcher (`AdoptSession`).
        struct TestSession: Equatable {
            let gatewayURL: String
            let token: String
        }

        /// Application Support, or the isolated run's temporary root.
        let root: URL
        let defaults: UserDefaults
        /// The name a shared screen's host shows for this device.
        let screenClientName: String
        /// Adopted once the core has started.
        let testSession: TestSession?
        /// Shown on the sign-in screen instead of adopted, so a test can sign
        /// in from the first-launch state.
        let signedOutTestSession: TestSession?
        /// The app replaces its content with a fixed preview (DEBUG only).
        let preview: Preview?
        /// Gateway sessions live in memory for an isolated run, never in the
        /// device's Keychain.
        let ephemeralCredentials: Bool

        enum Preview: Equatable {
            /// The connecting banner over an empty workspace.
            case connecting
            /// Provider quotas with fixture accounts; `details` opens the sheet.
            case quotas(details: Bool)
            /// The native WebRTC screen fixture (an encoded descriptor).
            case screen(String)
        }

        /// This process's launch, read once.
        @MainActor static let shared = IOSLaunchConfiguration.current

        @MainActor
        static var current: IOSLaunchConfiguration {
            let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            #if DEBUG
                return debug(environment: ProcessInfo.processInfo.environment, device: device, support: support)
            #else
                return IOSLaunchConfiguration(
                    root: support, defaults: .standard, screenClientName: device, testSession: nil,
                    signedOutTestSession: nil, preview: nil, ephemeralCredentials: false)
            #endif
        }

        #if DEBUG
            /// Maps the UI tests' `DIETER_IOS_*` launch environment.
            static func debug(environment: [String: String], device: String, support: URL) -> IOSLaunchConfiguration {
                var preview: Preview?
                if let mode = environment["DIETER_IOS_QUOTA_PREVIEW"] {
                    preview = .quotas(details: mode == "details")
                } else if let fixture = environment["DIETER_IOS_SCREEN_FIXTURE"] {
                    preview = .screen(fixture)
                } else if environment["DIETER_IOS_CONNECTION_PREVIEW"] == "1" {
                    preview = .connecting
                }
                let session = environment["DIETER_IOS_TEST_GATEWAY"].map { gateway in
                    TestSession(gatewayURL: gateway, token: environment["DIETER_IOS_TEST_TOKEN"] ?? "")
                }
                let signedOut = environment["DIETER_IOS_TEST_START_SIGNED_OUT"] == "1"
                guard session != nil || preview != nil else {
                    return IOSLaunchConfiguration(
                        root: support, defaults: .standard, screenClientName: device, testSession: nil,
                        signedOutTestSession: nil, preview: nil, ephemeralCredentials: false)
                }
                // Every isolated launch starts from nothing: its own state root
                // and defaults suite, discarded with the simulator.
                let launch = UUID().uuidString.lowercased()
                let root = FileManager.default.temporaryDirectory
                    .appending(path: "dieter-ios-test-\(launch)", directoryHint: .isDirectory)
                let defaults = UserDefaults(suiteName: "com.dbpprt.dieter.ios.test.\(launch)") ?? .standard
                return IOSLaunchConfiguration(
                    root: root, defaults: defaults, screenClientName: device,
                    testSession: signedOut ? nil : session, signedOutTestSession: signedOut ? session : nil,
                    preview: preview, ephemeralCredentials: true)
            }
        #endif
    }

    #if DEBUG
        /// Gateway sessions of an isolated test launch, gone when it exits.
        final class IOSEphemeralSecureStore: NSObject, NativeSecureStore, @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String: String] = [:]

            func read(key: String) -> String? { lock.withLock { values[key] } }
            func write(key: String, value: String) { lock.withLock { values[key] = value } }
            func delete(key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
        }
    #endif
#endif
