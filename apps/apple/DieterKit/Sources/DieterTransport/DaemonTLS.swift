import Dispatch
import Foundation
import GRPCNIOTransportHTTP2
import NIOCore
import NIOSSL

/// This install's device key as the TLS client sees it: the key behind the
/// client certificate the core builds. `sign` returns a DER ECDSA P-256
/// signature over SHA-256 of `message`, or empty data on failure.
public protocol DeviceSigner: AnyObject, Sendable {
    func sign(message: Data) -> Data
}

/// Daemon routes trust the device roster, never a CA: the server is accepted
/// only if its leaf certificate's DER SubjectPublicKeyInfo equals the key the
/// roster lists for that machine. Issuer, chain, validity, and host name are
/// ignored.
public enum DaemonKeyPinning {
    /// The DER SubjectPublicKeyInfo of a DER certificate; nil if it does not parse.
    public static func subjectPublicKeyInfo(certificateDER: Data) -> Data? {
        guard let certificate = try? NIOSSLCertificate(bytes: Array(certificateDER), format: .der) else {
            return nil
        }
        return subjectPublicKeyInfo(certificate)
    }

    static func subjectPublicKeyInfo(_ certificate: NIOSSLCertificate) -> Data? {
        (try? certificate.extractPublicKey().toSPKIBytes()).map { Data($0) }
    }

    /// Whether the leaf of `chain` (as the server sent it) carries exactly `daemonPublicKey`.
    public static func verify(_ chain: [NIOSSLCertificate], daemonPublicKey: Data) -> Bool {
        guard !daemonPublicKey.isEmpty, let leaf = chain.first, let key = subjectPublicKeyInfo(leaf) else {
            return false
        }
        return key == daemonPublicKey
    }

    /// `verify` for a DER-encoded chain.
    public static func verify(derChain: [Data], daemonPublicKey: Data) -> Bool {
        let chain = derChain.compactMap { try? NIOSSLCertificate(bytes: Array($0), format: .der) }
        return chain.count == derChain.count && verify(chain, daemonPublicKey: daemonPublicKey)
    }
}

/// Mutual TLS 1.3 to a daemon (direct candidates, WebRTC bridges, and relay
/// tunnels alike): the server must present `daemonPublicKey`, and this device
/// presents `clientCertificate` (DER), signing the handshake with `signer`.
public enum DaemonTLS {
    public static func security(
        daemonPublicKey: Data, clientCertificate: Data, signer: any DeviceSigner
    ) -> HTTP2ClientTransport.Posix.TransportSecurity {
        .mTLS(
            certificateChain: [.bytes(Array(clientCertificate), format: .der)],
            privateKey: .customPrivateKey(DeviceTLSKey(signer))
        ) { config in
            config.minimumTLSVersion = .tlsv13
            // Daemon routes are IP targets; the pinned key is the identity.
            config.serverCertificateVerification = .noHostnameVerification
            config.verifySignatureAlgorithms = [.ed25519]
            config.customVerificationCallback = { certificates, promise in
                let pinned = DaemonKeyPinning.verify(certificates, daemonPublicKey: daemonPublicKey)
                promise.succeed(pinned ? .certificateVerified(.init(nil)) : .failed)
            }
        }
    }
}

/// The device key behind the TLS client certificate. Signing may reach the
/// Secure Enclave, so it runs off the event loop.
struct DeviceTLSKey: NIOSSLCustomPrivateKey, Hashable {
    private let signer: any DeviceSigner

    init(_ signer: any DeviceSigner) {
        self.signer = signer
    }

    var signatureAlgorithms: [SignatureAlgorithm] { [.ecdsaSecp256R1Sha256] }

    func sign(channel: any Channel, algorithm: SignatureAlgorithm, data: ByteBuffer) -> EventLoopFuture<ByteBuffer> {
        let promise = channel.eventLoop.makePromise(of: ByteBuffer.self)
        let message = Data(data.readableBytesView)
        let signer = signer
        DispatchQueue.global(qos: .userInitiated).async {
            let signature = algorithm == .ecdsaSecp256R1Sha256 ? signer.sign(message: message) : Data()
            if signature.isEmpty {
                promise.fail(DeviceTLSKeyError.signingFailed)
            } else {
                promise.succeed(ByteBuffer(bytes: signature))
            }
        }
        return promise.futureResult
    }

    func decrypt(channel: any Channel, data: ByteBuffer) -> EventLoopFuture<ByteBuffer> {
        channel.eventLoop.makeFailedFuture(DeviceTLSKeyError.decryptionUnsupported)
    }

    static func == (lhs: DeviceTLSKey, rhs: DeviceTLSKey) -> Bool { lhs.signer === rhs.signer }

    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(signer)) }
}

enum DeviceTLSKeyError: Error {
    case signingFailed
    case decryptionUnsupported
}
