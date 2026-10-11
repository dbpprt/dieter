import CryptoKit
import DieterCore
import Foundation
import OSLog
import Synchronization
import UserNotifications

/// Gateway session tokens keyed by gateway origin (`https://host:port`), in
/// one JSON file only the user can read (0600).
public final class CoreFileSecureStore: NSObject, NativeSecureStore, Sendable {
    private let fileURL: URL
    private let lock = Mutex(())

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func read(key: String) -> String? {
        lock.withLock { _ in (try? load())?[key] }
    }

    public func write(key: String, value: String) {
        lock.withLock { _ in
            var tokens = (try? load()) ?? [:]
            tokens[key] = value
            try? persist(tokens)
        }
    }

    public func delete(key: String) {
        lock.withLock { _ in
            guard var tokens = try? load(), tokens.removeValue(forKey: key) != nil else { return }
            try? persist(tokens)
        }
    }

    private func load() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fileURL))
    }

    private func persist(_ tokens: [String: String]) throws {
        let directory = fileURL.deletingLastPathComponent()
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try JSONEncoder().encode(tokens).write(to: fileURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

/// Device-local preferences in a UserDefaults suite.
public final class CoreDefaultsSettings: NSObject, NativeSettings, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func string(key: String) -> String? { defaults.string(forKey: key) }

    public func putString(key: String, value: String?) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// The OAuth code exchange over URLSession.
public final class CoreURLSessionHttp: NSObject, NativeHttp, Sendable {
    public func postJson(url: String, body: String, completion: any NativeHttpCompletion) {
        let completion = NativeCallback(completion)
        guard let target = URL(string: url) else { return completion.value.completed(status: 0, body: "invalid URL") }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                completion.value.completed(
                    status: Int32((response as? HTTPURLResponse)?.statusCode ?? 0),
                    body: String(decoding: data, as: UTF8.self))
            } catch {
                completion.value.completed(status: 0, body: error.localizedDescription)
            }
        }
    }
}

/// Screen-session bindings are signed by the daemon's Ed25519 key.
public final class CoreCryptoKitSignatures: NSObject, NativeSignatures, Sendable {
    public func verifyEd25519(publicKey: Data, message: Data, signature: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }
}

/// The core's log, in the unified log under the app's subsystem.
public final class CoreOSLogger: NSObject, NativeLogger, Sendable {
    private let subsystem: String

    public init(subsystem: String) {
        self.subsystem = subsystem
    }

    public func log(level: Int32, tag: String, message: String) {
        let logger = Logger(subsystem: subsystem, category: tag)
        switch level {
        case 0: logger.debug("\(message, privacy: .public)")
        case 1: logger.info("\(message, privacy: .public)")
        default: logger.warning("\(message, privacy: .public)")
        }
    }
}

/// Local notifications the core decides to post. Actions are registered as
/// categories named after their action set, so the system shows the core's
/// buttons; the app's notification delegate routes taps back to the core.
public final class CoreUserNotifications: NSObject, NativeNotifications, Sendable {
    /// `userInfo` keys a delegate reads to route a tap.
    public static let keyInfo = "dieter.notification.key"
    public static let sessionInfo = "dieter.notification.session"
    private static let titles = ["MARK_DONE": "Mark done", "OPEN": "Open"]

    private let isEnabled: @Sendable () -> Bool
    private let registered = Mutex<Set<String>>([])

    /// `isEnabled` is the user's notification switch, read on every post.
    public init(isEnabled: @escaping @Sendable () -> Bool) {
        self.isEnabled = isEnabled
    }

    /// The notification center requires an app bundle; test runners and other
    /// unbundled processes would abort on first use.
    private static let available = Bundle.main.bundleIdentifier != nil

    public func post(
        key: String, role: String, title: String, text: String, expanded: String?, actions: [String], session: String?
    ) -> Bool {
        guard Self.available, isEnabled() else { return false }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = expanded ?? text
        content.threadIdentifier = role
        var info: [String: String] = [Self.keyInfo: key]
        if let session { info[Self.sessionInfo] = session }
        content.userInfo = info
        if !actions.isEmpty {
            let category = "dieter." + actions.joined(separator: ".")
            content.categoryIdentifier = category
            let isNew = registered.withLock { $0.insert(category).inserted }
            if isNew {
                center.getNotificationCategories { existing in
                    let buttons = actions.map { name in
                        UNNotificationAction(
                            identifier: name, title: Self.titles[name] ?? name,
                            options: name == "OPEN" ? [.foreground] : [])
                    }
                    var categories = existing.filter { $0.identifier != category }
                    categories.insert(
                        UNNotificationCategory(identifier: category, actions: buttons, intentIdentifiers: []))
                    UNUserNotificationCenter.current().setNotificationCategories(categories)
                }
            }
        }
        center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
        return true
    }

    public func cancel(key: String) {
        guard Self.available else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [key])
        center.removePendingNotificationRequests(withIdentifiers: [key])
    }
}
