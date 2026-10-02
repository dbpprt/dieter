import CryptoKit
import DieterAPI
import DieterCore
import Foundation
import Testing

@Test func remoteDesktopBindingMessageMatchesDaemonWireFormat() {
    let message = RemoteDesktopSessionTrust.bindingMessage(
        sessionID: "rd_one",
        nonce: "nonce",
        fingerprint: "sha-256 AA:BB",
        expiresAt: "2026-08-25T08:00:00Z",
        offerHash: Data([0, 1, 2]), controlGranted: true, displayID: "primary",
        inputProtocolVersion: DieterRemoteDesktopProtocol.number, inputEpoch: Data(repeating: 7, count: 16)
    )
    #expect(
        String(data: message, encoding: .utf8)
            == "dieter-remote-desktop-v\(DieterRemoteDesktopProtocol.number)\nrd_one\nnonce\nsha-256 AA:BB\n2026-08-25T08:00:00Z\nAAEC\ntrue\nprimary\n\(DieterRemoteDesktopProtocol.number)\nBwcHBwcHBwcHBwcHBwcHBw"
    )
}

@Test func remoteDesktopBindingRejectsSignatureWithoutControlAndEpoch() throws {
    let offer = "v=0\r\no=test"
    let answer = "v=0\r\na=fingerprint:sha-256 AA:BB\r\n"
    var binding = Dieter_V1_RemoteDesktopSessionBinding()
    binding.clientNonce = "nonce_fixture"
    binding.helperDtlsFingerprint = "sha-256 AA:BB"
    binding.expiresAt = "2099-08-25T08:00:00Z"
    binding.offerSha256 = Data(SHA256.hash(data: Data(offer.utf8)))
    binding.inputProtocolVersion = DieterRemoteDesktopProtocol.number
    binding.inputEpoch = Data(repeating: 1, count: 16)
    binding.daemonSignature = try #require(
        Data(base64Encoded: "ctCMwB2SL9Wk9JqpQzgtM+NQxXqUXGGKSSpQ1X2lNX3G3uS8UR7uKe5J8fjZheT1WxX3U5s37saWnSk7dqIADQ=="))
    let certificate = Data(
        """
        -----BEGIN CERTIFICATE-----
        MIIBYTCCAROgAwIBAgIUWcmlQ5i8ry6XFrGSInUHhVtT6bcwBQYDK2VwMCUxIzAh
        BgNVBAMMGkRpZXRlciBSZW1vdGUgRGVza3RvcCBUZXN0MCAXDTI2MDgyNTA2MzAy
        M1oYDzIxMjYwODAxMDYzMDIzWjAlMSMwIQYDVQQDDBpEaWV0ZXIgUmVtb3RlIERl
        c2t0b3AgVGVzdDAqMAUGAytlcAMhAK/kvlcnHBLF7CgDu3bGqnnFqiS1qDddmdfC
        2SuEjBCxo1MwUTAdBgNVHQ4EFgQUTRWfCy1GDKsD0d2TMOQ04Djoy0QwHwYDVR0j
        BBgwFoAUTRWfCy1GDKsD0d2TMOQ04Djoy0QwDwYDVR0TAQH/BAUwAwEB/zAFBgMr
        ZXADQQBccxXAQ41kKXSVZIV/OV/wSiYVreRAZ5kKZDnz//Ks54js7/FFkUoIVBBN
        bpWaGrNlFFB4ASZmaVDTqY2T0psO
        -----END CERTIFICATE-----
        """.utf8
    )
    let now = try #require(ISO8601DateFormatter().date(from: "2026-08-25T08:00:00Z"))

    do {
        try RemoteDesktopSessionTrust.verify(
            binding: binding, sessionID: "rd_fixture", clientNonce: "nonce_fixture",
            offerSDP: offer, answerSDP: answer, daemonCertificatePEM: certificate,
            now: now
        )
        Issue.record("a signature without the control binding was accepted")
    } catch RemoteDesktopSessionTrust.Failure.invalidSignature {
        // Expected: control authorization and the input epoch are now signed.
    }
}

@Test func remoteDesktopBindingRejectsExpiryBeforeCertificateVerification() {
    let offer = "v=0\r\no=test"
    let answer = "v=0\r\na=fingerprint:sha-256 AA:BB\r\n"
    var binding = Dieter_V1_RemoteDesktopSessionBinding()
    binding.clientNonce = "nonce"
    binding.helperDtlsFingerprint = "sha-256 AA:BB"
    binding.expiresAt = "2026-08-25T07:00:00Z"
    binding.offerSha256 = Data(SHA256.hash(data: Data(offer.utf8)))
    binding.inputProtocolVersion = DieterRemoteDesktopProtocol.number
    binding.inputEpoch = Data(repeating: 1, count: 16)
    do {
        try RemoteDesktopSessionTrust.verify(
            binding: binding, sessionID: "rd_one", clientNonce: "nonce",
            offerSDP: offer, answerSDP: answer, daemonCertificatePEM: Data(),
            now: try #require(ISO8601DateFormatter().date(from: "2026-08-25T08:00:00Z"))
        )
        Issue.record("expired binding was accepted")
    } catch RemoteDesktopSessionTrust.Failure.expiredBinding {
        // Expected: expiry is enforced before any untrusted certificate work.
    } catch {
        Issue.record("unexpected binding failure: \(error)")
    }
}
