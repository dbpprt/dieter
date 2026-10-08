#if os(iOS)
    import DieterAPI
    import DieterShared
    import Foundation
    import Metal
    import QuartzCore
    import SharedCore
    import UIKit
    @preconcurrency import WebRTC

    extension CoreScreenMedia {
        /// iPhone and iPad: screens draw through Metal.
        static func iOS() -> CoreScreenMedia {
            CoreScreenMedia { MTLCreateSystemDefaultDevice() == nil ? "Metal is unavailable on this device." : nil }
        }
    }

    #if DEBUG
        /// The disposable native screen fixture the UI tests start
        /// (tools/fixtures/screens): every screen signals through its
        /// loopback daemon API instead of a machine's route.
        final class IOSScreenFixtureRoutes: NSObject, NativeScreenFixture, Sendable {
            /// What the fixture writes once it listens, base64-encoded JSON.
            private struct Connection: Decodable {
                let url: String
                let certificate: Data
                let rtc: Data
                let token: String
            }

            private let url: String
            private let token: String
            private let certificate: String
            private let rtc: Data

            /// Nil when `encoded` is not the fixture's connection.
            init?(encoded: String) {
                guard let data = Data(base64Encoded: encoded),
                    let connection = try? JSONDecoder().decode(Connection.self, from: data)
                else { return nil }
                url = connection.url
                token = connection.token
                certificate = String(decoding: connection.certificate, as: UTF8.self)
                rtc = connection.rtc
            }

            func open() -> NativeScreenFixtureRoute? {
                NativeScreenFixtureRoute(
                    url: url, token: token, certificatePem: certificate, rtc: rtc, label: "Fixture loopback")
            }
        }
    #endif
#endif
