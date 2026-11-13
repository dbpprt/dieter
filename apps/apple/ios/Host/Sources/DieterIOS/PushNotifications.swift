import CryptoKit
import DieterCore
import Foundation
import DieterIdentity
import DieterPlatform
import Synchronization

/// A private key per gateway/account. Only its public key goes to the gateway;
/// a notification from another account cannot navigate the currently signed-in UI.
final class IOSPushKeys: Sendable {
    private let secureStore = CoreKeychainSecureStore(service: DistributionIdentity.iosBundleID + ".push")
    private let lock = Mutex(false)

    func allowPush(_ allowed: Bool) { lock.withLock { $0 = allowed } }

    func setToken(_ token: Data) {
        lock.withLock { _ in
            secureStore.write(key: "apns-token", value: token.map { String(format: "%02x", $0) }.joined())
        }
    }

    func device(accountKey: String) -> (NativePushDevice, Curve25519.KeyAgreement.PrivateKey)? {
        lock.withLock { allowed in
            let name =
                "private-key." + SHA256.hash(data: Data(accountKey.utf8)).map { String(format: "%02x", $0) }.joined()
            let agreement: Curve25519.KeyAgreement.PrivateKey
            if let encoded = secureStore.read(key: name), let data = Data(base64Encoded: encoded),
                let existing = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
            {
                agreement = existing
            } else {
                agreement = Curve25519.KeyAgreement.PrivateKey()
                let encoded = agreement.rawRepresentation.base64EncodedString()
                secureStore.write(key: name, value: encoded)
                guard secureStore.read(key: name) == encoded else { return nil }
            }
            // Binding the account is also needed before APNs returns a token (cold taps).
            let token = allowed ? secureStore.read(key: "apns-token") ?? "" : ""
            let sandbox = Bundle.main.object(forInfoDictionaryKey: "DieterAPNSEnvironment") as? String == "development"
            return (
                NativePushDevice(
                    token: token, publicKey: agreement.publicKey.rawRepresentation, sandbox: sandbox),
                agreement
            )
        }
    }

    static func cardId(sealed: Data, key: Curve25519.KeyAgreement.PrivateKey) -> String? {
        guard sealed.count >= 60 else { return nil }
        do {
            let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: sealed.prefix(32))
            let secret = try key.sharedSecretFromKeyAgreement(with: ephemeral)
            let info = Data("dieter-attention-v1".utf8)
            let symmetric = secret.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: Data(), sharedInfo: info, outputByteCount: 32)
            let box = try AES.GCM.SealedBox(combined: sealed.dropFirst(32))
            let plain = try AES.GCM.open(box, using: symmetric, authenticating: info)
            let value = try JSONDecoder().decode(Destination.self, from: plain)
            return value.cardId.isEmpty ? nil : value.cardId
        } catch { return nil }
    }

    private struct Destination: Decodable { let cardId: String }
}
