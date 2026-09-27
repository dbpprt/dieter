import Foundation

/// Time is a capability so lifecycle tests can advance deadlines without waiting.
package struct ClientClock: Sendable {
    package var now: @Sendable () -> Date
    package var sleep: @Sendable (Duration) async throws -> Void

    package init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }

    package static let live = ClientClock(
        now: { Date() },
        sleep: { duration in try await DieterTaskSleep.duration(duration) })
}
