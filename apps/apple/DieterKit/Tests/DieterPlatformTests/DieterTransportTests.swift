import DieterTransport
import Foundation
import GRPCNIOTransportHTTP2
import Testing

@Test func transportTargetsDoNotSendIPAddressesAsTLSServerNames() {
    #expect(DieterTransportTarget.hostKind("127.0.0.1") == .ipv4)
    #expect(DieterTransportTarget.hostKind("::1") == .ipv6)
    #expect(DieterTransportTarget.hostKind("fe80::1%en0") == .ipv6)
    #expect(DieterTransportTarget.hostKind("gateway.getdieter.com") == .dns)

    #expect(DieterTransportTarget.make(host: "127.0.0.1", port: 4242) is ResolvableTargets.IPv4)
    #expect(DieterTransportTarget.make(host: "::1", port: 4242) is ResolvableTargets.IPv6)
    #expect(DieterTransportTarget.make(host: "gateway.getdieter.com", port: 443) is ResolvableTargets.DNS)
}

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
    #expect(DaemonCertificatePinning.hasDaemonIdentity(CertificateFixtures.matching, daemonID: "ios-fixture"))
    #expect(!DaemonCertificatePinning.hasDaemonIdentity(CertificateFixtures.matching, daemonID: "ios"))
    #expect(!DaemonCertificatePinning.hasDaemonIdentity(CertificateFixtures.matching, daemonID: ""))
    #expect(!DaemonCertificatePinning.hasDaemonIdentity(CertificateFixtures.wrongDaemon, daemonID: "ios-fixture"))
    #expect(!DaemonCertificatePinning.hasDaemonIdentity(CertificateFixtures.dnsOnly, daemonID: "ios-fixture"))
    #expect(!DaemonCertificatePinning.hasDaemonIdentity(CertificateFixtures.noSAN, daemonID: "ios-fixture"))
    #expect(!DaemonCertificatePinning.hasDaemonIdentity(Data([0x30, 0x80, 0x00]), daemonID: "ios-fixture"))
}

@Test func directDaemonTrustRequiresEnrolledCAAndExactIdentity() {
    #expect(
        DaemonCertificatePinning.verify(
            [CertificateFixtures.matching], daemonCAPEM: CertificateFixtures.ca, daemonID: "ios-fixture"))
    #expect(
        !DaemonCertificatePinning.verify(
            [CertificateFixtures.matching], daemonCAPEM: CertificateFixtures.otherCA, daemonID: "ios-fixture"))
    #expect(
        !DaemonCertificatePinning.verify(
            [CertificateFixtures.matching], daemonCAPEM: CertificateFixtures.ca, daemonID: "another-daemon"))
    #expect(
        !DaemonCertificatePinning.verify(
            [CertificateFixtures.dnsOnly], daemonCAPEM: CertificateFixtures.ca, daemonID: "ios-fixture"))
    var tampered = CertificateFixtures.matching
    tampered[tampered.count - 1] ^= 0x01
    #expect(
        !DaemonCertificatePinning.verify(
            [tampered], daemonCAPEM: CertificateFixtures.ca, daemonID: "ios-fixture"))
    #expect(
        !DaemonCertificatePinning.verify(
            [], daemonCAPEM: CertificateFixtures.ca, daemonID: "ios-fixture"))
}
