import Foundation

/// Waking is asynchronous: CoreGraphics can list an online monitor before
/// ScreenCaptureKit exposes it. Retry only a missing selection, never an OS
/// permission/framework error, and preserve explicit display-ID selection.
func discoverCaptureDisplay<Display>(
    maxAttempts: Int = 21,
    isStopped: () -> Bool,
    query: () async throws -> Display?,
    sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
) async throws -> Display {
    precondition(maxAttempts > 0)
    for attempt in 0..<maxAttempts {
        try Task.checkCancellation()
        guard !isStopped() else { throw CaptureError.stopped }
        let display = try await query()
        try Task.checkCancellation()
        guard !isStopped() else { throw CaptureError.stopped }
        if let display { return display }
        if attempt + 1 < maxAttempts { try await sleep(100_000_000) }
    }
    throw CaptureError.noDisplay
}
