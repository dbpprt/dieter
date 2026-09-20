import CryptoKit
import DieterAPI
import Foundation
import Security

/// Verifies that a remote-screen answer belongs to the enrolled daemon and to
/// the exact offer, display, and input epoch requested by this client.
public enum RemoteDesktopSessionTrust {
    public enum Failure: LocalizedError {
        case invalidBinding
        case expiredBinding
        case invalidCertificate
        case invalidSignature

        public var errorDescription: String? {
            switch self {
            case .invalidBinding:
                "The daemon returned a screen-sharing answer that was not bound to this request."
            case .expiredBinding: "The daemon screen-sharing binding has expired."
            case .invalidCertificate: "The enrolled daemon certificate is invalid."
            case .invalidSignature: "The daemon screen-sharing signature could not be verified."
            }
        }
    }

    public static func verify(
        binding: Dieter_V1_RemoteDesktopSessionBinding,
        sessionID: String,
        clientNonce: String,
        offerSDP: String,
        answerSDP: String,
        daemonCertificatePEM: Data,
        now: Date = Date()
    ) throws {
        let offerHash = Data(SHA256.hash(data: Data(offerSDP.utf8)))
        guard binding.clientNonce == clientNonce,
            binding.offerSha256 == offerHash,
            binding.helperDtlsFingerprint == fingerprint(in: answerSDP),
            binding.inputProtocolVersion == DieterContract.number,
            binding.inputEpoch.count == 16,
            !sessionID.isEmpty
        else { throw Failure.invalidBinding }
        guard let expires = timestamp(binding.expiresAt), expires > now else {
            throw Failure.expiredBinding
        }
        guard let certificate = certificate(fromPEM: daemonCertificatePEM),
            let publicKey = SecCertificateCopyKey(certificate)
        else { throw Failure.invalidCertificate }
        let message = bindingMessage(
            sessionID: sessionID, nonce: clientNonce,
            fingerprint: binding.helperDtlsFingerprint, expiresAt: binding.expiresAt,
            offerHash: offerHash, controlGranted: binding.controlGranted,
            displayID: binding.displayID, inputProtocolVersion: binding.inputProtocolVersion,
            inputEpoch: binding.inputEpoch
        )
        var keyError: Unmanaged<CFError>?
        guard let rawKey = SecKeyCopyExternalRepresentation(publicKey, &keyError) as Data?,
            let signingKey = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey),
            signingKey.isValidSignature(binding.daemonSignature, for: message)
        else {
            throw Failure.invalidSignature
        }
    }

    public static func bindingMessage(
        sessionID: String,
        nonce: String,
        fingerprint: String,
        expiresAt: String,
        offerHash: Data,
        controlGranted: Bool,
        displayID: String,
        inputProtocolVersion: UInt32,
        inputEpoch: Data
    ) -> Data {
        let encodedHash = offerHash.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Data(
            [
                "dieter-remote-desktop-v\(inputProtocolVersion)", sessionID, nonce, fingerprint, expiresAt,
                encodedHash, controlGranted ? "true" : "false", displayID, String(inputProtocolVersion),
                inputEpoch.base64URLEncodedString(),
            ].joined(separator: "\n").utf8)
    }

    public static func fingerprint(in sdp: String) -> String {
        for line in sdp.split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("a=fingerprint:") {
                return String(value.dropFirst("a=fingerprint:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    private static func timestamp(_ value: String) -> Date? {
        DieterTimestamp.date(from: value)
    }

    private static func certificate(fromPEM pem: Data) -> SecCertificate? {
        guard let text = String(data: pem, encoding: .utf8) else { return nil }
        let body =
            text
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let der = Data(base64Encoded: body) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }
}

extension Data {
    fileprivate func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
