import CryptoKit
import DieterShared
import Foundation
import OSLog
import Synchronization
import UserNotifications

/// Gateway session tokens keyed by gateway origin (`https://host:port`), in
/// one JSON file only the user can read (0600).
package final class CoreFileSecureStore: NSObject, NativeSecureStore, Sendable {
    private let fileURL: URL
    private let lock = Mutex(())

    package init(fileURL: URL) {
        self.fileURL = fileURL
    }

    package func read(key: String) -> String? {
        lock.withLock { _ in (try? load())?[key] }
    }

    package func write(key: String, value: String) {
        lock.withLock { _ in
            var tokens = (try? load()) ?? [:]
            tokens[key] = value
            try? persist(tokens)
        }
    }

    package func delete(key: String) {
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
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try JSONEncoder().encode(tokens).write(to: fileURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

/// Device-local preferences in a UserDefaults suite.
package final class CoreDefaultsSettings: NSObject, NativeSettings, @unchecked Sendable {
    private let defaults: UserDefaults

    package init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    package func string(key: String) -> String? { defaults.string(forKey: key) }

    package func putString(key: String, value: String?) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// The OAuth code exchange over URLSession.
package final class CoreURLSessionHttp: NSObject, NativeHttp, Sendable {
    package func postJson(url: String, body: String, completion: any NativeHttpCompletion) {
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
package final class CoreCryptoKitSignatures: NSObject, NativeSignatures, Sendable {
    package func verifyEd25519(publicKey: Data, message: Data, signature: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }
}

/// The core's log, in the unified log under the app's subsystem.
package final class CoreOSLogger: NSObject, NativeLogger, Sendable {
    private let subsystem: String

    package init(subsystem: String) {
        self.subsystem = subsystem
    }

    package func log(level: Int32, tag: String, message: String) {
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
package final class CoreUserNotifications: NSObject, NativeNotifications, Sendable {
    /// `userInfo` keys a delegate reads to route a tap.
    package static let keyInfo = "dieter.notification.key"
    package static let sessionInfo = "dieter.notification.session"
    private static let titles = ["MARK_DONE": "Mark done", "OPEN": "Open"]

    private let isEnabled: @Sendable () -> Bool
    private let registered = Mutex<Set<String>>([])

    /// `isEnabled` is the user's notification switch, read on every post.
    package init(isEnabled: @escaping @Sendable () -> Bool) {
        self.isEnabled = isEnabled
    }

    /// The notification center requires an app bundle; test runners and other
    /// unbundled processes would abort on first use.
    private static let available = Bundle.main.bundleIdentifier != nil

    package func post(
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
                        UNNotificationAction(identifier: name, title: Self.titles[name] ?? name, options: name == "OPEN" ? [.foreground] : [])
                    }
                    var categories = existing.filter { $0.identifier != category }
                    categories.insert(UNNotificationCategory(identifier: category, actions: buttons, intentIdentifiers: []))
                    UNUserNotificationCenter.current().setNotificationCategories(categories)
                }
            }
        }
        center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
        return true
    }

    package func cancel(key: String) {
        guard Self.available else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [key])
        center.removePendingNotificationRequests(withIdentifiers: [key])
    }
}
