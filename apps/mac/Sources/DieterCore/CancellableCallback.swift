import Foundation

/// Bridges a callback API without keeping a canceled task suspended forever.
/// Both cancellation and a late callback may finish it; exactly one wins.
public func awaitCancellableCallback<Value: Sendable>(
    _ start: @Sendable (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void
) async throws -> Value {
    let completion = CallbackCompletion<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            completion.install(continuation)
            if !Task.isCancelled { start { completion.finish($0) } }
        }
    } onCancel: {
        completion.finish(.failure(CancellationError()))
    }
}

private final class CallbackCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let result: Result<Value, Error>? = lock.withLock { () -> Result<Value, Error>? in
            if let result = self.result { return result }
            self.continuation = continuation
            return nil as Result<Value, Error>?
        }
        if let result { continuation.resume(with: result) }
    }

    func finish(_ result: Result<Value, Error>) {
        let continuation: CheckedContinuation<Value, Error>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            if continuation == nil { self.result = result }
            return continuation
        }
        continuation?.resume(with: result)
    }
}
