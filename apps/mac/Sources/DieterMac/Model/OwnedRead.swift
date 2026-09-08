import Foundation

/// One transport read per surface. Repeated requests for the same target share
/// the result; a new target cancels the old transport without affecting remote work.
@MainActor
final class OwnedRead<Value: Sendable> {
    private var pending: (key: String, id: UUID, task: Task<Value, Error>)?

    func value(key: String, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let pending, pending.key == key {
            let result = try await pending.task.value
            try Task.checkCancellation()
            guard !pending.task.isCancelled else { throw CancellationError() }
            return result
        }
        cancel()
        let id = UUID()
        let task = Task { try await operation() }
        pending = (key, id, task)
        defer { if pending?.id == id { pending = nil } }
        let result = try await task.value
        try Task.checkCancellation()
        guard pending?.id == id else { throw CancellationError() }
        return result
    }

    func cancel() {
        pending?.task.cancel()
        pending = nil
    }
}
