import Foundation
import UserNotifications

/// The notification center's delegate for the core's local notifications
/// (`CoreUserNotifications`): it shows them while the app is in front, and
/// hands every tap and action back to the app with the notification's core
/// key, which the app sends to the core as a `NotificationResponse`.
public final class CoreNotificationResponder: NSObject, UNUserNotificationCenterDelegate, Sendable {
    /// `key` is the core's notification key; `action` is empty for a tap on
    /// the notification itself, else the action's name (e.g. "MARK_READ").
    public typealias Handler = @MainActor @Sendable (_ key: String, _ action: String) async -> Void

    private let handler: Handler

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Becomes the current notification center's delegate. The center keeps
    /// its delegate weakly, so the caller retains the responder. Unbundled
    /// processes (test runners) have no notification center and are skipped.
    public func install() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// The action a response names: empty for the default tap, nil when the
    /// user only dismissed the notification.
    public static func action(for identifier: String) -> String? {
        switch identifier {
        case UNNotificationDefaultActionIdentifier: ""
        case UNNotificationDismissActionIdentifier: nil
        default: identifier
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let key = info[CoreUserNotifications.keyInfo] as? String, !key.isEmpty,
            let action = Self.action(for: response.actionIdentifier)
        else { return }
        await handler(key, action)
    }
}
