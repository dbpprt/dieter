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
        sleep: { duration in
            let parts = duration.components
            let nanos = max(0, Double(parts.seconds) * 1_000_000_000 + Double(parts.attoseconds) / 1_000_000_000)
            try await Task.sleep(nanoseconds: UInt64(min(nanos, Double(UInt64.max - 1_000_000))))
        })
}
