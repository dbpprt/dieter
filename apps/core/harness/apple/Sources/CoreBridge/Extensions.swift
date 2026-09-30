import CryptoKit
import DieterShared
import Foundation
import Synchronization

/// Keychain stand-in: the apps pass their Keychain-backed store.
public final class MemorySecureStore: NSObject, NativeSecureStore, Sendable {
    private let values = Mutex<[String: String]>([:])
    public func read(key: String) -> String? { values.withLock { $0[key] } }
    public func write(key: String, value: String) { values.withLock { $0[key] = value } }
    public func delete(key: String) { _ = values.withLock { $0.removeValue(forKey: key) } }
}

/// UserDefaults stand-in.
public final class MemorySettings: NSObject, NativeSettings, Sendable {
    private let values = Mutex<[String: String]>([:])
    public func string(key: String) -> String? { values.withLock { $0[key] } }
    public func putString(key: String, value: String?) { values.withLock { $0[key] = value } }
}

/// The OAuth code exchange over URLSession.
public final class URLSessionHttp: NSObject, NativeHttp, Sendable {
    public func postJson(url: String, body: String, completion: any NativeHttpCompletion) {
        let completion = KotlinCallback(completion)
        guard let target = URL(string: url) else { return completion.value.completed(status: 0, body: "invalid URL") }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                completion.value.completed(status: Int32((response as? HTTPURLResponse)?.statusCode ?? 0), body: String(decoding: data, as: UTF8.self))
            } catch {
                completion.value.completed(status: 0, body: error.localizedDescription)
            }
        }
    }
}

/// Screen-session bindings are signed by the daemon's Ed25519 key.
public final class CryptoKitSignatures: NSObject, NativeSignatures, Sendable {
    public func verifyEd25519(publicKey: Data, message: Data, signature: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }
}

public final class PrintLogger: NSObject, NativeLogger, Sendable {
    public func log(level: Int32, tag: String, message: String) {
        print("\(["D", "I", "W"][Int(min(max(level, 0), 2))])/\(tag): \(message)")
    }
}
