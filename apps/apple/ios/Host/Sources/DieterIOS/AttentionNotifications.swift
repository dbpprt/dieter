import DieterCore
import Foundation
import DieterIdentity
import OSLog
import UIKit
import UserNotifications

/// Presents only the attention transitions the core selected. Notification taps
/// enter shared navigation; displaying the latest transcript owns its read receipt.
@MainActor
final class IOSAttentionNotifications: NSObject, NativeAttentionNotifications, UNUserNotificationCenterDelegate {
    private nonisolated static let prefix = "dieter.attention."
    private nonisolated static let cardKey = "dieter.cardId"
    private nonisolated static let accountKey = "dieter.account"
    private nonisolated let keys = IOSPushKeys()
    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: DistributionIdentity.iosBundleID, category: "notifications")
    private var permissionRequested = false
    private var delivery: Task<Void, Never>?
    private var operations: [String: @MainActor () async -> Void] = [:]
    private var order: [String] = []
    private lazy var push = NativePushDelivery(decoder: PushDecoder(keys: keys))

    private final class PushDecoder: NSObject, NativePushDecoder {
        let keys: IOSPushKeys
        init(keys: IOSPushKeys) { self.keys = keys; super.init() }
        func cardId(accountKey: String, sealed: Data) -> String? {
            guard let (_, key) = keys.device(accountKey: accountKey) else { return nil }
            return IOSPushKeys.cardId(sealed: sealed, key: key)
        }
    }
    var refreshRegistration: (() -> Void)?
    var openCard: ((String) -> Void)?

    override init() {
        super.init()
        center.delegate = self
    }

    /// Prompt once after sign-in, when the app is foregrounded. Denials are
    /// respected; the operator can change alerts, Lock Screen and badges in Settings.
    func requestPermission(force: Bool = false) {
        guard (!permissionRequested || force), UIApplication.shared.applicationState == .active else { return }
        #if DEBUG || targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains(where: { $0.contains("fixture_url") }) { return }
        #endif
        permissionRequested = true
        enqueue(key: "authorization") { [self] in
            let settings = await center.notificationSettings()
            var authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            if settings.authorizationStatus == .notDetermined {
                do { authorized = try await center.requestAuthorization(options: [.alert, .sound, .badge]) } catch {
                    logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            keys.allowPush(authorized)
            if authorized { UIApplication.shared.registerForRemoteNotifications() }
            refreshRegistration?()
        }
    }

    /// Coalesce fast workspace frames. Keep a bounded queue even when system
    /// notification calls are slow; the badge and Inbox still cover every task.
    private func enqueue(key: String, _ operation: @escaping @MainActor () async -> Void) {
        if operations[key] == nil { order.append(key) }
        operations[key] = operation
        while order.count > 67, let oldest = order.firstIndex(where: { $0.hasPrefix("post:") }) {
            operations.removeValue(forKey: order.remove(at: oldest))
        }
        guard delivery == nil else { return }
        delivery = Task {
            while !order.isEmpty {
                let key = order.removeFirst()
                let next = operations.removeValue(forKey: key)
                await next?()
            }
            delivery = nil
        }
    }

    nonisolated func post(cardId: String, title: String, text: String) {
        DispatchQueue.main.async { [self] in
            enqueue(key: "post:" + cardId) { [self] in
                guard !push.available, let account = push.accountKey else { return }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = text
                content.sound = .default
                content.threadIdentifier = "dieter.attention"
                content.userInfo = [Self.cardKey: cardId, Self.accountKey: account]
                do {
                    try await center.add(
                        UNNotificationRequest(
                            identifier: Self.prefix + cardId, content: content, trigger: nil))
                } catch {
                    logger.error("Attention notification failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    nonisolated func reconcile(cardIds: [String], badge: Int32) {
        DispatchQueue.main.async { [self] in
            enqueue(key: "reconcile") { [self] in
                let keep = Set(cardIds.map { Self.prefix + $0 })
                let notifications = await center.deliveredNotifications()
                let delivered = notifications.map { $0.request.identifier }
                let pending = await center.pendingNotificationRequests().map(\.identifier)
                let stale = Set(delivered + pending).filter { $0.hasPrefix(Self.prefix) && !keep.contains($0) }
                center.removeDeliveredNotifications(withIdentifiers: Array(stale))
                center.removePendingNotificationRequests(withIdentifiers: Array(stale))
                let stalePush = notifications.filter { notification in
                    guard let sealed = Self.sealed(notification.request.content.userInfo),
                        let id = push.cardId(sealed: sealed)
                    else { return false }
                    return !cardIds.contains(id)
                }.map { $0.request.identifier }
                center.removeDeliveredNotifications(withIdentifiers: stalePush)
                do { try await center.setBadgeCount(Int(badge)) } catch {
                    logger.error("Attention badge failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    nonisolated func reset() {
        DispatchQueue.main.async { [self] in
            push.reset()
            for key in order where key.hasPrefix("post:") { operations.removeValue(forKey: key) }
            order.removeAll { $0.hasPrefix("post:") }
            enqueue(key: "reset") { [self] in
                let remote = await center.deliveredNotifications().filter {
                    Self.sealed($0.request.content.userInfo) != nil
                }.map { $0.request.identifier }
                center.removeDeliveredNotifications(withIdentifiers: remote)
            }
        }
        reconcile(cardIds: [], badge: 0)
    }

    func setPushToken(_ token: Data) { keys.setToken(token); refreshRegistration?() }

    nonisolated func device(accountKey: String) -> NativePushDevice? {
        guard let (device, _) = keys.device(accountKey: accountKey) else { return nil }
        DispatchQueue.main.async { [self] in
            if let id = push.bind(accountKey: accountKey) { openCard?(id) }
        }
        return device
    }

    nonisolated func registered(available: Bool) {
        DispatchQueue.main.async { [self] in push.registered(available: available) }
    }

    nonisolated func visible(cardId: String?) {
        DispatchQueue.main.async { [self] in push.visible(cardId: cardId) }
    }

    private nonisolated static func sealed(_ info: [AnyHashable: Any]) -> Data? {
        (info["dieter_sealed"] as? String).flatMap { Data(base64Encoded: $0) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        guard let sealed = Self.sealed(notification.request.content.userInfo) else {
            return notification.request.identifier.hasPrefix(Self.prefix) ? [.banner, .list, .sound] : [.badge]
        }
        // APNs can arrive before the live workspace, or while its transport is
        // reconnecting. The shared core checks account, visibility and duplicates.
        return await MainActor.run { [self] in
            return push.present(sealed: sealed) ? [.banner, .list, .sound, .badge] : [.badge]
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            let cardId = response.notification.request.content.userInfo[Self.cardKey] as? String,
            let account = response.notification.request.content.userInfo[Self.accountKey] as? String
        {
            DispatchQueue.main.async { [weak self] in
                if let id = self?.push.tapLocal(accountKey: account, cardId: cardId) { self?.openCard?(id) }
            }
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            let sealed = Self.sealed(response.notification.request.content.userInfo)
        {
            DispatchQueue.main.async { [weak self] in
                if let id = self?.push.tap(sealed: sealed) { self?.openCard?(id) }
            }
        }
        completionHandler()
    }
}
