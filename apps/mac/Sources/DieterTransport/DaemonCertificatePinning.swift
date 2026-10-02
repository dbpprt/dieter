import Foundation
import Security
import X509

/// Direct daemon routes are IP targets, so TLS cannot check a hostname. The
/// daemon's leaf must instead chain to the CA enrolled for it and carry its
/// exact SPIFFE identity, `spiffe://board/daemon/<id>`.
package enum DaemonCertificatePinning {
    package static func verify(
        _ derChain: [Data],
        daemonCAPEM: Data,
        daemonID: String
    ) -> Bool {
        guard let leafData = derChain.first,
            SecCertificateCreateWithData(nil, leafData as CFData) != nil,
            let caDER = pemCertificateDER(daemonCAPEM),
            let ca = SecCertificateCreateWithData(nil, caDER as CFData)
        else { return false }
        let chain = derChain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard chain.count == derChain.count else { return false }
        var trust: SecTrust?
        guard
            SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateBasicX509(), &trust)
                == errSecSuccess,
            let trust,
            SecTrustSetAnchorCertificates(trust, [ca] as CFArray) == errSecSuccess,
            SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
            SecTrustEvaluateWithError(trust, nil)
        else { return false }
        return hasDaemonIdentity(leafData, daemonID: daemonID)
    }

    /// Match only a URI subject-alternative-name, never a common name, DNS SAN,
    /// substring, or another extension containing the same bytes. X509's DER
    /// parser is available on both iOS and macOS; SecCertificateCopyValues is not.
    package static func hasDaemonIdentity(_ der: Data, daemonID: String) -> Bool {
        guard !daemonID.isEmpty,
            let certificate = try? Certificate(derEncoded: Array(der)),
            let names = try? certificate.extensions.subjectAlternativeNames
        else { return false }
        let expected = "spiffe://board/daemon/\(daemonID)"
        return names.contains { name in
            guard case .uniformResourceIdentifier(let value) = name else { return false }
            return value == expected
        }
    }

    private static func pemCertificateDER(_ pem: Data) -> Data? {
        guard let value = String(data: pem, encoding: .utf8) else { return nil }
        let body =
            value
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        return Data(base64Encoded: body)
    }
}
