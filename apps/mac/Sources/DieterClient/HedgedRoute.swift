import Foundation

/// Select the first healthy transport, giving the preferred route a head start.
/// Only connection setup races; application RPCs are never replayed.
@MainActor package enum HedgedRoute {
    package static func connect<Value: Sendable>(
        delay: Duration = .milliseconds(1_000),
        preferred: @escaping @MainActor () async throws -> Value,
        fallback: @escaping @MainActor () async throws -> Value,
        dispose: @escaping @MainActor (Value) -> Void
    ) async throws -> Value {
        let race = RouteAttempt(dispose: dispose)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let value: Value = try await withCheckedThrowingContinuation { continuation in
                race.start(continuation, delay: delay, preferred: preferred, fallback: fallback)
            }
            if Task.isCancelled {
                dispose(value)
                throw CancellationError()
            }
            return value
        } onCancel: {
            Task { @MainActor in race.cancel() }
        }
    }
}

@MainActor private final class RouteAttempt<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var preferredTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var failed = 0
    private var finished = false
    private let dispose: @MainActor (Value) -> Void

    init(dispose: @escaping @MainActor (Value) -> Void) { self.dispose = dispose }

    func start(
        _ continuation: CheckedContinuation<Value, Error>, delay: Duration,
        preferred: @escaping @MainActor () async throws -> Value,
        fallback: @escaping @MainActor () async throws -> Value
    ) {
        guard !finished else { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        preferredTask = Task {
            do { finish(.success(try await preferred())) } catch {
                finish(.failure(error))
                startFallback(fallback)
            }
        }
        timer = Task {
            do { try await Task.sleep(for: delay) } catch { return }
            startFallback(fallback)
        }
    }

    private func startFallback(_ fallback: @escaping @MainActor () async throws -> Value) {
        guard !finished, fallbackTask == nil else { return }
        timer?.cancel(); timer = nil
        fallbackTask = Task {
            do { finish(.success(try await fallback())) } catch { finish(.failure(error)) }
        }
    }

    private func finish(_ result: Result<Value, Error>) {
        guard !finished else {
            if case .success(let value) = result { dispose(value) }
            return
        }
        if case .failure = result {
            failed += 1
            guard failed == 2 else { return }
        }
        finished = true
        let receiver = continuation
        continuation = nil
        cancelTasks()
        receiver?.resume(with: result)
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        let receiver = continuation
        continuation = nil
        cancelTasks()
        receiver?.resume(throwing: CancellationError())
    }

    private func cancelTasks() {
        preferredTask?.cancel(); preferredTask = nil
        fallbackTask?.cancel(); fallbackTask = nil
        timer?.cancel(); timer = nil
    }
}
