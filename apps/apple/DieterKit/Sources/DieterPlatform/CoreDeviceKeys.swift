import CryptoKit
import Darwin
import DieterCore
import DieterIdentity
import DieterTransport
import Foundation
import OSLog
import Synchronization

/// This install's ECDSA P-256 device key, which the account's device roster
/// lists and every daemon route authenticates. It is a Secure Enclave key
/// where the hardware allows (created without an access-control policy, so
/// signing never prompts) and a software CryptoKit key otherwise. `store`
/// keeps the key's representation: on macOS a user-only file, never the
/// Keychain. The key survives restarts and sign-out until `reset()`.
public final class CoreDeviceKeys: NSObject, NativeDeviceKeys, DeviceSigner, Sendable {
    static let logger = Logger(subsystem: DistributionIdentity.bundlePrefix + ".platform", category: "DeviceKeys")
    private let store: any DeviceKeyStore
    private let platformName: String
    private let name: String
    private let secureEnclave: Bool
    private let key = Mutex<DeviceKey?>(nil)

    /// `platform` is "macos" or "ios"; `deviceName` is what other devices
    /// show. `secureEnclave` false always uses a software key.
    public init(
        store: any DeviceKeyStore, platform: String, deviceName: String,
        secureEnclave: Bool = SecureEnclave.isAvailable
    ) {
        self.store = store
        platformName = platform
        name = deviceName
        self.secureEnclave = secureEnclave
    }

    public func platform() -> String { platformName }

    public func deviceName() -> String { name }

    public func publicKey() -> Data { (try? current().publicKey) ?? Data() }

    public func sign(message: Data) -> Data {
        do {
            return try current().sign(message)
        } catch {
            Self.logger.error("Device key signing failed: \(error.localizedDescription, privacy: .public)")
            return Data()
        }
    }

    public func reset() {
        key.withLock { key in
            key = nil
            store.delete()
        }
    }

    /// Whether the current key lives in the Secure Enclave.
    public var isHardwareBacked: Bool {
        guard case .enclave = try? current() else { return false }
        return true
    }

    /// The stored key, or a new one, created and stored on first use.
    private func current() throws -> DeviceKey {
        try key.withLock { key in
            if let key { return key }
            if let stored = store.load() {
                if let restored = DeviceKey(stored: stored) {
                    key = restored
                    return restored
                }
                // A key from another Mac (a migration or restore) or a damaged
                // file: this install becomes a new device and pairs again.
                Self.logger.error("The stored device key is unusable; creating a new one.")
            }
            let created = try DeviceKey.create(secureEnclave: secureEnclave)
            do {
                try store.save(created.stored)
            } catch {
                Self.logger.error("Could not store the device key: \(error.localizedDescription, privacy: .public)")
            }
            key = created
            return created
        }
    }
}

/// A device key and its stored form: a tag and the key's
/// `dataRepresentation` (Secure Enclave, usable only on this device's
/// enclave) or `rawRepresentation` (software).
enum DeviceKey: Sendable {
    case enclave(SecureEnclave.P256.Signing.PrivateKey)
    case software(P256.Signing.PrivateKey)

    private struct Stored: Codable {
        static let enclave = "secure-enclave"
        static let software = "software"
        var kind: String
        var key: Data
    }

    static func create(secureEnclave: Bool) throws -> DeviceKey {
        if secureEnclave {
            do {
                return .enclave(try SecureEnclave.P256.Signing.PrivateKey())
            } catch {
                // E.g. a virtual machine without an enclave, or a build
                // without the entitlements it needs: a software key instead.
                CoreDeviceKeys.logger.error(
                    "Secure Enclave key unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
        return .software(P256.Signing.PrivateKey())
    }

    init?(stored: Data) {
        guard let value = try? JSONDecoder().decode(Stored.self, from: stored) else { return nil }
        switch value.kind {
        case Stored.enclave:
            guard let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: value.key) else {
                return nil
            }
            self = .enclave(key)
        case Stored.software:
            guard let key = try? P256.Signing.PrivateKey(rawRepresentation: value.key) else { return nil }
            self = .software(key)
        default:
            return nil
        }
    }

    var stored: Data {
        let value =
            switch self {
            case .enclave(let key): Stored(kind: Stored.enclave, key: key.dataRepresentation)
            case .software(let key): Stored(kind: Stored.software, key: key.rawRepresentation)
            }
        return (try? JSONEncoder().encode(value)) ?? Data()
    }

    /// The DER SubjectPublicKeyInfo (uncompressed point).
    var publicKey: Data {
        switch self {
        case .enclave(let key): key.publicKey.derRepresentation
        case .software(let key): key.publicKey.derRepresentation
        }
    }

    /// A DER ECDSA signature over SHA-256 of `message`.
    func sign(_ message: Data) throws -> Data {
        switch self {
        case .enclave(let key): try key.signature(for: message).derRepresentation
        case .software(let key): try key.signature(for: message).derRepresentation
        }
    }
}

/// Where the device key's representation is kept.
public protocol DeviceKeyStore: Sendable {
    func load() -> Data?
    func save(_ data: Data) throws
    func delete()
}

/// The Mac's device key file: user-only (0600) in a user-only (0700)
/// directory beside the gateway sessions. No Keychain item, so ad-hoc and
/// development builds never prompt.
public struct DeviceKeyFile: DeviceKeyStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> Data? {
        try? Data(contentsOf: url)
    }

    public func save(_ data: Data) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // Created private before the key is written, then replaced atomically.
        let staging = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        guard manager.createFile(atPath: staging.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: staging)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            guard Darwin.rename(staging.path, url.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    public func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// The iOS device key: a device-only Keychain item of the app's service.
public struct DeviceKeyKeychain: DeviceKeyStore {
    private let store: CoreKeychainSecureStore
    private let account: String

    public init(store: CoreKeychainSecureStore = CoreKeychainSecureStore(), account: String = "dieter.device-key") {
        self.store = store
        self.account = account
    }

    public func load() -> Data? {
        store.read(key: account).flatMap { Data(base64Encoded: $0) }
    }

    public func save(_ data: Data) throws {
        let encoded = data.base64EncodedString()
        store.write(key: account, value: encoded)
        guard store.read(key: account) == encoded else { throw CocoaError(.fileWriteUnknown) }
    }

    public func delete() {
        store.delete(key: account)
    }
}
