import Foundation

/// Avoids the duration-based `Task.sleep` overload affected by Swift #81771
/// in the toolchain currently used for Dieter release builds.
enum DieterTaskSleep {
    static func seconds(_ seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        let nanoseconds = min(seconds * 1_000_000_000, Double(UInt64.max))
        try await Task.sleep(nanoseconds: UInt64(nanoseconds))
    }

    static func milliseconds(_ milliseconds: Int) async throws {
        guard milliseconds > 0 else { return }
        let (nanoseconds, overflow) = UInt64(milliseconds).multipliedReportingOverflow(by: 1_000_000)
        try await Task.sleep(nanoseconds: overflow ? .max : nanoseconds)
    }
}
