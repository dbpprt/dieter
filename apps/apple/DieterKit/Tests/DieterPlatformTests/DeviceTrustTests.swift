import CryptoKit
import DieterTransport
import Foundation
import Testing

@testable import DieterPlatform

/// The golden roster vectors every implementation checks
/// (tests/fixtures/roster/vectors.json): Ed25519 daemon and recovery
/// signatures and ECDSA P-256 app signatures over the canonical entry bytes.
@Test func rosterVectorSignaturesVerifyWithCryptoKit() throws {
    struct Vectors: Decodable {
        struct Device: Decodable {
            let publicKey: String
            let deviceId: String
        }
        struct Entry: Decodable {
            let signer: String
            let canonical: String
            let signature: String
        }
        let devices: [Device]
        let entries: [Entry]
    }
    let file = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../../../../tests/fixtures/roster/vectors.json").standardized
    let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: file))
    let keys = Dictionary(uniqueKeysWithValues: vectors.devices.map { ($0.deviceId, try! hex($0.publicKey)) })
    let signatures = CoreCryptoKitSignatures()
    var verified = (ed25519: 0, ecdsa: 0)
    for entry in vectors.entries {
        let key = try #require(keys[entry.signer])
        let message = try hex(entry.canonical)
        let signature = try hex(entry.signature)
        var tampered = message
        tampered[tampered.count - 1] ^= 0x01
        if key.starts(with: ed25519SPKIPrefix) {
            let raw = key.suffix(32)
            #expect(signatures.verifyEd25519(publicKey: raw, message: message, signature: signature))
            #expect(!signatures.verifyEd25519(publicKey: raw, message: tampered, signature: signature))
            verified.ed25519 += 1
        } else {
            #expect(signatures.verifyEcdsaP256(publicKey: key, message: message, signature: signature))
            #expect(!signatures.verifyEcdsaP256(publicKey: key, message: tampered, signature: signature))
            #expect(!signatures.verifyEcdsaP256(publicKey: key.dropLast(), message: message, signature: signature))
            #expect(!signatures.verifyEcdsaP256(publicKey: key, message: message, signature: signature.dropLast()))
            verified.ecdsa += 1
        }
    }
    #expect(verified.ed25519 > 0 && verified.ecdsa > 0, "the vectors cover both algorithms")
}

@Test func softwareDeviceKeysPersistInAPrivateFileUntilReset() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "dieter-device-key-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "device-key.json")
    let keys = CoreDeviceKeys(
        store: DeviceKeyFile(url: file), platform: "macos", deviceName: "Test Mac", secureEnclave: false)
    #expect(keys.platform() == "macos" && keys.deviceName() == "Test Mac")
    let publicKey = keys.publicKey()
    #expect(try P256.Signing.PublicKey(derRepresentation: publicKey).derRepresentation == publicKey)
    #expect(!keys.isHardwareBacked)

    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let folder = try FileManager.default.attributesOfItem(atPath: directory.path)
    #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)

    let message = Data("dieter-roster-v1 canonical bytes".utf8)
    let signature = keys.sign(message: message)
    #expect(CoreCryptoKitSignatures().verifyEcdsaP256(publicKey: publicKey, message: message, signature: signature))

    // A restart reads the same key back.
    let restarted = CoreDeviceKeys(
        store: DeviceKeyFile(url: file), platform: "macos", deviceName: "Test Mac", secureEnclave: false)
    #expect(restarted.publicKey() == publicKey)

    // Reset deletes it; the next use creates and stores another key.
    restarted.reset()
    #expect(!FileManager.default.fileExists(atPath: file.path))
    let replaced = restarted.publicKey()
    #expect(!replaced.isEmpty && replaced != publicKey)
    #expect(FileManager.default.fileExists(atPath: file.path))

    // An unreadable file makes this install a new device rather than failing.
    try Data("not a key".utf8).write(to: file)
    let damaged = CoreDeviceKeys(
        store: DeviceKeyFile(url: file), platform: "macos", deviceName: "Test Mac", secureEnclave: false)
    #expect(!damaged.publicKey().isEmpty && damaged.publicKey() != replaced)
}

/// Apple silicon Macs create Secure Enclave keys without entitlements or
/// prompts; virtual machines without an enclave skip this test.
@Test(.enabled(if: SecureEnclave.isAvailable))
func secureEnclaveDeviceKeysSignSilentlyAndSurviveARestart() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "dieter-device-key-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "device-key.json")
    let keys = CoreDeviceKeys(store: DeviceKeyFile(url: file), platform: "macos", deviceName: "Test Mac")
    let publicKey = keys.publicKey()
    #expect(keys.isHardwareBacked)
    let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    #expect(stored?["kind"] as? String == "secure-enclave")

    let message = Data("handshake".utf8)
    let restarted = CoreDeviceKeys(store: DeviceKeyFile(url: file), platform: "macos", deviceName: "Test Mac")
    #expect(restarted.publicKey() == publicKey)
    #expect(
        CoreCryptoKitSignatures().verifyEcdsaP256(
            publicKey: publicKey, message: message, signature: restarted.sign(message: message)))
    restarted.reset()
}

@Test func daemonPinningAcceptsOnlyTheRosterKey() throws {
    let daemon = try TestCertificates.daemon()
    let other = try TestCertificates.daemon()
    #expect(DaemonKeyPinning.subjectPublicKeyInfo(certificateDER: daemon.certificate) == daemon.publicKey)
    #expect(DaemonKeyPinning.verify(derChain: [daemon.certificate], daemonPublicKey: daemon.publicKey))
    // The leaf decides; issuer, validity, and names are ignored.
    #expect(
        DaemonKeyPinning.verify(derChain: [daemon.certificate, other.certificate], daemonPublicKey: daemon.publicKey))
    #expect(!DaemonKeyPinning.verify(derChain: [other.certificate], daemonPublicKey: daemon.publicKey))
    #expect(
        !DaemonKeyPinning.verify(derChain: [other.certificate, daemon.certificate], daemonPublicKey: daemon.publicKey))
    #expect(!DaemonKeyPinning.verify(derChain: [daemon.certificate], daemonPublicKey: Data()))
    #expect(!DaemonKeyPinning.verify(derChain: [], daemonPublicKey: daemon.publicKey))
    #expect(!DaemonKeyPinning.verify(derChain: [Data([0x30, 0x80, 0x00])], daemonPublicKey: daemon.publicKey))
    var truncated = daemon.publicKey
    truncated.removeLast()
    #expect(!DaemonKeyPinning.verify(derChain: [daemon.certificate], daemonPublicKey: truncated))
}

let ed25519SPKIPrefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])

func hex(_ value: String) throws -> Data {
    var data = Data(capacity: value.count / 2)
    var index = value.startIndex
    while index < value.endIndex {
        let next = value.index(index, offsetBy: 2)
        guard let byte = UInt8(value[index..<next], radix: 16) else { throw CocoaError(.coderInvalidValue) }
        data.append(byte)
        index = next
    }
    return data
}
