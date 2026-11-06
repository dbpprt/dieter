import CryptoKit
import Foundation
import GRPCCore
import Network
import Synchronization
import X509

/// Certificates as the daemon and the core make them: a self-signed Ed25519
/// daemon certificate, and a device certificate that only carries the device
/// key (nobody checks its issuer signature).
enum TestCertificates {
    struct Daemon {
        let certificate: Data
        let publicKey: Data
        /// PKCS#8 DER of the daemon's Ed25519 key.
        let privateKeyDER: Data
    }

    static func daemon() throws -> Daemon {
        let key = Curve25519.Signing.PrivateKey()
        let certificateKey = Certificate.PrivateKey(key)
        let name = try DistinguishedName { CommonName("Test daemon") }
        let certificate = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: certificateKey.publicKey,
            notValidBefore: Date().addingTimeInterval(-3_600), notValidAfter: Date().addingTimeInterval(3_600),
            issuer: name, subject: name, signatureAlgorithm: .ed25519, extensions: Certificate.Extensions(),
            issuerPrivateKey: certificateKey)
        // PKCS#8 for Ed25519 (RFC 8410).
        let pkcs8 = Data([
            0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
        ])
        return Daemon(
            certificate: Data(try certificate.serializeAsPEM().derBytes),
            publicKey: ed25519SPKIPrefix + key.publicKey.rawRepresentation, privateKeyDER: pkcs8 + key.rawRepresentation
        )
    }

    /// A certificate whose SubjectPublicKeyInfo is `devicePublicKey` (DER).
    static func device(_ devicePublicKey: Data) throws -> Data {
        let issuer = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let name = try DistinguishedName { CommonName("Test device") }
        let certificate = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(try P256.Signing.PublicKey(derRepresentation: devicePublicKey)),
            notValidBefore: Date().addingTimeInterval(-3_600), notValidAfter: Date().addingTimeInterval(3_600),
            issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256, extensions: Certificate.Extensions(),
            issuerPrivateKey: issuer)
        return Data(try certificate.serializeAsPEM().derBytes)
    }
}

struct RawBytes: MessageSerializer, MessageDeserializer {
    func serialize<Bytes: GRPCContiguousBytes>(_ message: [UInt8]) throws -> Bytes { Bytes(message) }
    func deserialize<Bytes: GRPCContiguousBytes>(_ serializedMessageBytes: Bytes) throws -> [UInt8] {
        serializedMessageBytes.withUnsafeBytes { Array($0) }
    }
}

/// A TCP client to a loopback port, as the daemon TLS client connects to a tunnel.
final class LoopbackSocket: Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dieter.tests.loopback")

    init(port: Int) {
        connection = NWConnection(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = Mutex(false)
            connection.stateUpdateHandler = { state in
                let result: Result<Void, any Error>? =
                    switch state {
                    case .ready: .success(())
                    case .failed(let error), .waiting(let error): .failure(error)
                    case .cancelled: .failure(CancellationError())
                    default: nil
                    }
                guard let result else { return }
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(with: result) }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
        }
    }

    /// The next bytes, or nil once the peer closed the connection.
    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: complete ? nil : Data())
                }
            }
        }
    }

    func close() { connection.cancel() }
}

/// Polls `condition` every 10 ms for up to `seconds`.
func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        guard Date() < deadline else { return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
}
