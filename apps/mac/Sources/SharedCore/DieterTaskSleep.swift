import Foundation

/// One cancellation and saturation contract for client clocks and route timers.
/// Retains the nanosecond overload workaround for Swift #81771 on supported toolchains.
package enum DieterTaskSleep {
    package static func nanoseconds(seconds: TimeInterval) -> UInt64 {
        guard seconds > 0 else { return 0 }  // Includes NaN and negative infinity.
        let value = seconds * 1_000_000_000
        // Double(UInt64.max) rounds up to 2^64, so clamp before conversion.
        guard value < Double(UInt64.max) else { return .max }
        return UInt64(value)
    }

    package static func nanoseconds(duration: Duration) -> UInt64 {
        guard duration > .zero else { return 0 }
        var (seconds, attoseconds) = duration.components
        if attoseconds < 0 {
            seconds -= 1
            attoseconds += 1_000_000_000_000_000_000
        }
        let (whole, overflow) = UInt64(seconds).multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { return .max }
        let (result, fractionOverflow) = whole.addingReportingOverflow(UInt64(attoseconds / 1_000_000_000))
        return fractionOverflow ? .max : result
    }

    package static func duration(_ duration: Duration) async throws {
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: nanoseconds(duration: duration))
    }

    package static func seconds(_ seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: nanoseconds(seconds: seconds))
    }

    package static func milliseconds(_ milliseconds: Int) async throws {
        try await duration(.milliseconds(milliseconds))
    }
}
