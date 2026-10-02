import DieterCore
import Foundation
import Synchronization
import Testing

@Test func callbackCancellationCompletesWithoutWaitingForNativeCallback() async throws {
    let callback = Mutex<(@Sendable (Result<Int, Error>) -> Void)?>(nil)
    let task = Task { try await awaitCancellableCallback { finish in callback.withLock { $0 = finish } } as Int }
    for _ in 0..<1_000 {
        if callback.withLock({ $0 != nil }) { break }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    // A native callback after cancellation is harmless and cannot resume twice.
    callback.withLock { $0 }?(.success(7))
}
