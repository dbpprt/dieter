import DieterAPI
import Foundation
import GRPCCore

enum DieterConversationID {
    static func isServerBacked(_ id: String) -> Bool {
        !id.hasPrefix("local_")
    }
}

enum DieterRPCFailure {
    static func isTransient(_ error: Error) -> Bool {
        guard let rpcError = error as? RPCError else { return false }
        return [
            .cancelled,
            .deadlineExceeded,
            .unavailable,
        ].contains(rpcError.code)
    }

    static func isPermanent(_ error: Error) -> Bool {
        guard let rpcError = error as? RPCError else { return false }
        return [.notFound, .invalidArgument, .permissionDenied, .failedPrecondition].contains(rpcError.code)
    }

    static func message(for error: Error) -> String {
        guard let rpcError = error as? RPCError else { return error.localizedDescription }
        let detail = scrub(rpcError.message)
        return detail.isEmpty ? "gRPC \(rpcError.code)" : "gRPC \(rpcError.code): \(detail)"
    }

    static func scrub(_ value: String) -> String {
        var value = value
            .replacingOccurrences(of: "[\\r\\n\\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "(?i)bearer\\s+[^ ]+", with: "Bearer [redacted]", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count > 500 {
            value = String(value.prefix(500)) + "…"
        }
        return value
    }
}

enum DieterConversationOpenFailureDisposition: Equatable {
    case ignore
    case retry
    case report
}

enum DieterConversationOpenFailurePolicy {
    static func disposition(
        for error: Error,
        selectionMatches: Bool,
        cancellationRetries: Int
    ) -> DieterConversationOpenFailureDisposition {
        guard selectionMatches else { return .ignore }
        let cancelled = error is CancellationError || (error as? RPCError)?.code == .cancelled
        if cancelled && cancellationRetries == 0 { return .retry }
        return .report
    }
}

enum DieterOutboxPolicy {
    static func removeUndelivered(
        from entries: inout [DieterOutboxEntry],
        endpointID: String
    ) -> [DieterOutboxEntry] {
        let removed = entries.filter { $0.endpointID == endpointID && $0.serverID == nil }
        entries.removeAll { $0.endpointID == endpointID && $0.serverID == nil }
        return removed
    }

    static func nextIndex(
        in entries: [DieterOutboxEntry],
        endpointID: String,
        now: Date = Date()
    ) -> Int? {
        entries.firstIndex {
            $0.endpointID == endpointID &&
                $0.serverID == nil &&
                $0.state != .failed &&
                ($0.nextAttemptAt == nil || $0.nextAttemptAt! <= now)
        }
    }

    static func nextIndex(
        in entries: [DieterOutboxEntry],
        endpointIDs: [String],
        now: Date = Date()
    ) -> Int? {
        endpointIDs.lazy.compactMap { endpointID in
            nextIndex(in: entries, endpointID: endpointID, now: now)
        }.first
    }

    static func nextRetryDelay(
        in entries: [DieterOutboxEntry],
        endpointID: String,
        now: Date = Date()
    ) -> TimeInterval? {
        entries.lazy
            .filter { $0.endpointID == endpointID && $0.serverID == nil && $0.state != .failed }
            .compactMap(\.nextAttemptAt)
            .map { max(0, $0.timeIntervalSince(now)) }
            .min()
    }

    static func nextRetryDelay(
        in entries: [DieterOutboxEntry],
        endpointIDs: Set<String>,
        now: Date = Date()
    ) -> TimeInterval? {
        entries.lazy
            .filter {
                endpointIDs.contains($0.endpointID) &&
                    $0.serverID == nil &&
                    $0.state != .failed
            }
            .compactMap(\.nextAttemptAt)
            .map { max(0, $0.timeIntervalSince(now)) }
            .min()
    }

    static func backoff(after attempts: Int) -> TimeInterval {
        min(30, Double(1 << min(attempts, 4)))
    }

    static func retargetDependencies(
        in entries: inout [DieterOutboxEntry],
        from optimisticID: String,
        to serverID: String
    ) throws {
        for index in entries.indices where entries[index].kind == .sendMessage && entries[index].serverID == nil {
            var request = try Dieter_V1_SendMessageRequest(serializedBytes: entries[index].request)
            guard request.cardID == optimisticID else { continue }
            request.cardID = serverID
            entries[index].request = try request.serializedData()
        }
    }
}
