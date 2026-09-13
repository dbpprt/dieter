import DieterClient
import DieterAPI
import DieterCore
import Foundation
import Testing

private enum CertificateFixtures {
    static let ca = Data(
        """
        -----BEGIN CERTIFICATE-----
        MIIBczCCASWgAwIBAgIUVrYmgebsYito7752DiEtKhzPB7IwBQYDK2VwMCYxJDAi
        BgNVBAMMG0RpZXRlciBpT1MgaXNvbGF0ZWQgdGVzdCBDQTAgFw0yNjA5MTIyMjIw
        MzdaGA8yMTI2MDgxOTIyMjAzN1owJjEkMCIGA1UEAwwbRGlldGVyIGlPUyBpc29s
        YXRlZCB0ZXN0IENBMCowBQYDK2VwAyEANiJUz3e8aC8ysAI4SEUYBj2kRowvXqbU
        mgUxYgXI+sijYzBhMB0GA1UdDgQWBBQvbnaJDUYWjF4LN099PdwJDsUpljAfBgNV
        HSMEGDAWgBQvbnaJDUYWjF4LN099PdwJDsUpljAPBgNVHRMBAf8EBTADAQH/MA4G
        A1UdDwEB/wQEAwIBBjAFBgMrZXADQQBHgvXyBtaeH+xSvGWuskrzOBC7riXHKRVw
        41EgD1/hquJ+mBtjoUQRFwSw3k6xsSDQqw9iOVxIW4egAruc3iUI
        -----END CERTIFICATE-----
        """.utf8)
    static let otherCA = Data(
        """
        -----BEGIN CERTIFICATE-----
        MIIBczCCASWgAwIBAgIUblNFka7x+5M5IyUMQx7pEpSXjakwBQYDK2VwMCYxJDAi
        BgNVBAMMG0RpZXRlciBpT1MgaXNvbGF0ZWQgdGVzdCBDQTAgFw0yNjA5MTIyMjIw
        MzdaGA8yMTI2MDgxOTIyMjAzN1owJjEkMCIGA1UEAwwbRGlldGVyIGlPUyBpc29s
        YXRlZCB0ZXN0IENBMCowBQYDK2VwAyEAcTE029keYm7RlVANSHQy5YRF0x2Ukh2C
        QSqewFgNpa+jYzBhMB0GA1UdDgQWBBTho64H+FpM2OwjaODQM7hdwmUklDAfBgNV
        HSMEGDAWgBTho64H+FpM2OwjaODQM7hdwmUklDAPBgNVHRMBAf8EBTADAQH/MA4G
        A1UdDwEB/wQEAwIBBjAFBgMrZXADQQBEKzGq69hXllfjp6bFRN6UWNivs2R7agqu
        wLUK+mOVZveDhZ2CPr6vFIUCJ9S4Hr0vDzNv/kb2QpgPDMRS7YIN
        -----END CERTIFICATE-----
        """.utf8)
    static let matching = Data(
        base64Encoded:
            "MIIBpjCCAVigAwIBAgIUCjz89juq2975Ge5XTnYjvgbTwmIwBQYDK2VwMCYxJDAiBgNVBAMMG0RpZXRlciBpT1MgaXNvbGF0ZWQgdGVzdCBDQTAgFw0yNjA5MTIyMjIwMzdaGA8yMTI2MDgxOTIyMjAzN1owLDEqMCgGA1UEAwwhc3BpZmZlOi8vYm9hcmQvZGFlbW9uL2lvcy1maXh0dXJlMCowBQYDK2VwAyEAbxUUTJXBFXY/q09GQ/TeWSF5f57wKM0wlBa+zuGzZkGjgY8wgYwwDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCB4AwLAYDVR0RBCUwI4Yhc3BpZmZlOi8vYm9hcmQvZGFlbW9uL2lvcy1maXh0dXJlMB0GA1UdDgQWBBQ0Q9HQ0JM1S0Rleac0nzL210nhTTAfBgNVHSMEGDAWgBQvbnaJDUYWjF4LN099PdwJDsUpljAFBgMrZXADQQDIq2O0mBJeS17We3y7o2hif8lV6bRY+cyvcIuJ7N0lSaaJPGJnw0svvO9nX73A60j3GtEciLY2v65PDpBY8ZIH"
    )!
    static let wrongDaemon = Data(
        base64Encoded:
            "MIIBrDCCAV6gAwIBAgIUCjz89juq2975Ge5XTnYjvgbTwmMwBQYDK2VwMCYxJDAiBgNVBAMMG0RpZXRlciBpT1MgaXNvbGF0ZWQgdGVzdCBDQTAgFw0yNjA5MTIyMjIwMzdaGA8yMTI2MDgxOTIyMjAzN1owLDEqMCgGA1UEAwwhc3BpZmZlOi8vYm9hcmQvZGFlbW9uL2lvcy1maXh0dXJlMCowBQYDK2VwAyEAp3VJ1g5rb3HABsdmO3Nx+T4nl2PTRth2MHvDCVv5aGSjgZUwgZIwDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCB4AwMgYDVR0RBCswKYYnc3BpZmZlOi8vYm9hcmQvZGFlbW9uL2lvcy1maXh0dXJlLW90aGVyMB0GA1UdDgQWBBSzTMsuOPL/oYDKLRy3QjLRXjfS9TAfBgNVHSMEGDAWgBQvbnaJDUYWjF4LN099PdwJDsUpljAFBgMrZXADQQDGt2594tgtBza68EYT1HEeu8me/c4aMlTMyS/leqN7xElMjf125SaCXGLQ4uBL3rxQIdVDR67jdiatmyqfbD4O"
    )!
    static let dnsOnly = Data(
        base64Encoded:
            "MIIBpjCCAVigAwIBAgIUCjz89juq2975Ge5XTnYjvgbTwmQwBQYDK2VwMCYxJDAiBgNVBAMMG0RpZXRlciBpT1MgaXNvbGF0ZWQgdGVzdCBDQTAgFw0yNjA5MTIyMjIwMzdaGA8yMTI2MDgxOTIyMjAzN1owLDEqMCgGA1UEAwwhc3BpZmZlOi8vYm9hcmQvZGFlbW9uL2lvcy1maXh0dXJlMCowBQYDK2VwAyEAfmmDOWH/82IraS27AjcnZJjNv/CSduAK2u/SkKKMWmGjgY8wgYwwDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCB4AwLAYDVR0RBCUwI4Ihc3BpZmZlOi8vYm9hcmQvZGFlbW9uL2lvcy1maXh0dXJlMB0GA1UdDgQWBBS8wNJ82CxdBrT/E0LYdYyIbNH1vDAfBgNVHSMEGDAWgBQvbnaJDUYWjF4LN099PdwJDsUpljAFBgMrZXADQQAIPeEWW75wBALIqzgb6mKvBTLI1rVTPhJkD6WmrbXzAmk+h+IWt/07adyXDB6trz8JV8La1/PC4s7839Vd+MAC"
    )!
    static let noSAN = Data(
        base64Encoded:
            "MIIBdjCCASigAwIBAgIUCjz89juq2975Ge5XTnYjvgbTwmUwBQYDK2VwMCYxJDAiBgNVBAMMG0RpZXRlciBpT1MgaXNvbGF0ZWQgdGVzdCBDQTAgFw0yNjA5MTIyMjIwMzdaGA8yMTI2MDgxOTIyMjAzN1owLDEqMCgGA1UEAwwhc3BpZmZlOi8vYm9hcmQvZGFlbW9uL2lvcy1maXh0dXJlMCowBQYDK2VwAyEAjYun9nZZ+L3p50Erbd6BHoDojkf68tTsVSG+RL4z2iyjYDBeMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMB0GA1UdDgQWBBRc1HkU6RgNtvsnWAWsWtL3dcq/VjAfBgNVHSMEGDAWgBQvbnaJDUYWjF4LN099PdwJDsUpljAFBgMrZXADQQD84z9ZDHUj8zMg1yJQ5XteBJmwUsGpzPtAmlgZwU+LoBdD0DbGxeMgtNQfs1xhf0HkGphnWJJoOM06T+VDg30E"
    )!
}

@Test func daemonIdentityOnlyAcceptsExactURISubjectAlternativeName() {
    #expect(DieterRPC.certificateHasDaemonIdentity(CertificateFixtures.matching, daemonID: "ios-fixture"))
    #expect(!DieterRPC.certificateHasDaemonIdentity(CertificateFixtures.matching, daemonID: "ios"))
    #expect(!DieterRPC.certificateHasDaemonIdentity(CertificateFixtures.matching, daemonID: ""))
    #expect(!DieterRPC.certificateHasDaemonIdentity(CertificateFixtures.wrongDaemon, daemonID: "ios-fixture"))
    #expect(!DieterRPC.certificateHasDaemonIdentity(CertificateFixtures.dnsOnly, daemonID: "ios-fixture"))
    #expect(!DieterRPC.certificateHasDaemonIdentity(CertificateFixtures.noSAN, daemonID: "ios-fixture"))
    #expect(!DieterRPC.certificateHasDaemonIdentity(Data([0x30, 0x80, 0x00]), daemonID: "ios-fixture"))
}

@Test func directDaemonTrustRequiresEnrolledCAAndExactIdentity() {
    #expect(
        DieterRPC.verifyDaemonCertificateChain(
            [CertificateFixtures.matching], daemonCAPEM: CertificateFixtures.ca, daemonID: "ios-fixture"))
    #expect(
        !DieterRPC.verifyDaemonCertificateChain(
            [CertificateFixtures.matching], daemonCAPEM: CertificateFixtures.otherCA, daemonID: "ios-fixture"))
    #expect(
        !DieterRPC.verifyDaemonCertificateChain(
            [CertificateFixtures.matching], daemonCAPEM: CertificateFixtures.ca, daemonID: "another-daemon"))
    #expect(
        !DieterRPC.verifyDaemonCertificateChain(
            [CertificateFixtures.dnsOnly], daemonCAPEM: CertificateFixtures.ca, daemonID: "ios-fixture"))
    var tampered = CertificateFixtures.matching
    tampered[tampered.count - 1] ^= 0x01
    #expect(
        !DieterRPC.verifyDaemonCertificateChain(
            [tampered], daemonCAPEM: CertificateFixtures.ca, daemonID: "ios-fixture"))
    #expect(
        !DieterRPC.verifyDaemonCertificateChain(
            [], daemonCAPEM: CertificateFixtures.ca, daemonID: "ios-fixture"))
}

@Test func installationIdentityPersistsWithPlatformPrefix() throws {
    let suite = "dieter-ios-installation-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = DieterSyncPersistence.installationID(defaults: defaults)
    #expect(DieterSyncPersistence.installationID(defaults: defaults) == first)
    #if os(iOS)
        #expect(first.hasPrefix("ios_"))
    #else
        #expect(first.hasPrefix("mac_"))
    #endif
    defaults.set("existing-installation", forKey: "DieterSyncClientID")
    #expect(DieterSyncPersistence.installationID(defaults: defaults) == "existing-installation")
}

// Tests only this randomly-named service. Existing account sessions are never read,
// replaced, or enumerated. Run inside the signed iOS test host for Keychain access.
#if os(iOS)
    @Test func keychainSeparatesGatewaysPersistsAndRemovesOnlySelectedOrigin() async throws {
        let service = "com.dbpprt.dieter.ios.tests.\(UUID().uuidString)"
        let firstOrigin = "https://first.invalid:443"
        let secondOrigin = "https://second.invalid:443"
        let store = DieterCredentialKeychainStore(service: service)
        do {
            try await store.save("first-token", for: firstOrigin)
            try await store.save("updated-token", for: firstOrigin)
            try await store.save("second-token", for: secondOrigin)
            let reloaded = DieterCredentialKeychainStore(service: service)
            #expect(await reloaded.token(for: firstOrigin) == "updated-token")
            #expect(await reloaded.token(for: secondOrigin) == "second-token")
            try await reloaded.remove(for: firstOrigin)
            #expect(await reloaded.token(for: firstOrigin) == nil)
            #expect(await reloaded.token(for: secondOrigin) == "second-token")
            try await reloaded.remove(for: firstOrigin)
        } catch {
            try? await store.remove(for: firstOrigin)
            try? await store.remove(for: secondOrigin)
            throw error
        }
        try await store.remove(for: secondOrigin)
    }
#endif

@Test func remoteOnlyRouteSelectionNeverProbesDeviceLoopback() {
    func candidate(_ host: String, network: String = "lan", priority: Int32 = 0) -> Dieter_Gateway_V1_DirectCandidate {
        var value = Dieter_Gateway_V1_DirectCandidate()
        value.id = host; value.host = host; value.port = 4242; value.network = network; value.priority = priority
        return value
    }
    let targets = [
        candidate("localhost"), candidate("LOCALHOST."), candidate("127.0.0.1"), candidate("127.42.0.9"),
        candidate("::1"), candidate("[::1]"), candidate("::ffff:127.0.0.1"),
        candidate("192.168.1.12", network: "LOOPBACK"),
        candidate("192.168.1.20", priority: 10), candidate("100.64.10.20", priority: 20),
    ]
    #expect(DirectCandidateScope.nonLoopback.ordered(targets).map(\.host) == ["100.64.10.20", "192.168.1.20"])
    #expect(DirectCandidateScope.all.ordered(targets).count == targets.count)
    #expect(DirectCandidateScope.loopbackOnly.ordered(targets).map(\.host) == ["192.168.1.12"])
}
