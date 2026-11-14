import Testing
import UserNotifications

@testable import DieterPlatform

/// A tap on a core notification reaches the core as its key and action: the
/// default tap is the empty action, a dismissal is no response at all, and
/// the core's own actions keep their names and have titled buttons.
struct NotificationResponderTests {
    @Test func responsesNameTheCoresActions() {
        #expect(CoreNotificationResponder.action(for: UNNotificationDefaultActionIdentifier) == "")
        #expect(CoreNotificationResponder.action(for: UNNotificationDismissActionIdentifier) == nil)
        #expect(CoreNotificationResponder.action(for: "MARK_READ") == "MARK_READ")
        #expect(CoreNotificationResponder.action(for: "ARCHIVE") == "ARCHIVE")
    }

    @Test func mailActionsHaveButtonTitles() {
        #expect(CoreUserNotifications.titles["MARK_READ"] == "Mark as Read")
        #expect(CoreUserNotifications.titles["ARCHIVE"] == "Archive")
        #expect(CoreUserNotifications.titles["OPEN"] == "Open")
    }

    @Test func mailCategoriesOpenOnlyForOpen() {
        let category = CoreUserNotifications.category(
            "dieter.OPEN.MARK_READ.ARCHIVE", actions: ["OPEN", "MARK_READ", "ARCHIVE"])
        #expect(category.identifier == "dieter.OPEN.MARK_READ.ARCHIVE")
        #expect(category.actions.map(\.title) == ["Open", "Mark as Read", "Archive"])
        #expect(category.actions.map { $0.options.contains(.foreground) } == [true, false, false])
    }
}
