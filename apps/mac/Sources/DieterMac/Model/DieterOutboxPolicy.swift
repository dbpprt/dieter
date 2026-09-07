import DieterAPI
import CryptoKit
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
    /// Idempotent conversation creates use the same deterministic identifier
    /// on the daemon. Knowing it lets the sync stream acknowledge a create
    /// before the unary CreateCard/CreateChat response returns, avoiding a
    /// transient authoritative row beside its optimistic counterpart.
    static func expectedConversationID(clientID: String, commandID: String) -> String? {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandID = commandID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !commandID.isEmpty, clientID.count <= 200, commandID.count <= 200 else {
            return nil
        }
        let digest = SHA256.hash(data: Data("\(clientID)\0\(commandID)".utf8))
        return "c_" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func synchronizedConversationID(
        for entry: DieterOutboxEntry,
        visibleConversationIDs: Set<String>
    ) -> String? {
        guard entry.serverID == nil,
              entry.kind == .createCard || entry.kind == .createChat,
              let expected = expectedConversationID(clientID: entry.clientID, commandID: entry.commandID),
              visibleConversationIDs.contains(expected) else { return nil }
        return expected
    }

    static func retargetedCards(
        _ cards: [Dieter_V1_Card],
        from optimisticID: String,
        to serverID: String,
        authoritative: Dieter_V1_Card? = nil
    ) -> [Dieter_V1_Card] {
        guard optimisticID != serverID else { return cards }

        if cards.contains(where: { $0.id == serverID }) {
            var keptServer = false
            return cards.compactMap { card in
                if card.id == optimisticID { return nil }
                guard card.id == serverID else { return card }
                guard !keptServer else { return nil }
                keptServer = true
                return card
            }
        }

        var retargeted = false
        return cards.compactMap { card in
            guard card.id == optimisticID else { return card }
            guard !retargeted else { return nil }
            retargeted = true
            if let authoritative, authoritative.id == serverID { return authoritative }
            var card = card
            card.id = serverID
            return card
        }
    }

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

    /// Overlays local sends into their chronological transcript position.
    ///
    /// Failed sends remain in the durable outbox until the user retries or
    /// removes them. Rebuilding a projection used to append those retained
    /// messages after the authoritative tail, which made an old failure look
    /// newer than turns that had already run successfully.
    static func overlayOptimisticMessages(
        _ snapshot: Dieter_V1_ConversationSnapshot,
        entries: [DieterOutboxEntry]
    ) -> Dieter_V1_ConversationSnapshot {
        let cardID = snapshot.detail.card.id.isEmpty
            ? snapshot.conversation.cardID
            : snapshot.detail.card.id
        guard !cardID.isEmpty else { return snapshot }

        let sends = entries.compactMap { entry -> (DieterOutboxEntry, Dieter_V1_SendMessageRequest)? in
            guard entry.kind == .sendMessage,
                  let request = try? Dieter_V1_SendMessageRequest(serializedBytes: entry.request),
                  request.cardID == cardID else { return nil }
            return (entry, request)
        }
        guard !sends.isEmpty else { return snapshot }

        let optimisticIDs = Set(sends.map { $0.0.optimisticID })
        let queuedIDs = Set(snapshot.conversation.queue.map(\.id))
        var messages = snapshot.conversation.messages.filter { !optimisticIDs.contains($0.id) }

        for (entry, request) in sends.sorted(by: {
            if $0.0.createdAt == $1.0.createdAt { return $0.0.commandID < $1.0.commandID }
            return $0.0.createdAt < $1.0.createdAt
        }) where !queuedIDs.contains(entry.optimisticID) {
            var message = Dieter_V1_UiMessage()
            message.id = entry.optimisticID
            message.role = "user"
            message.parts = request.parts
            message.metadataJson = optimisticMessageMetadata(createdAt: entry.createdAt)
            let insertionIndex = messages.firstIndex {
                guard let date = messageCreatedAt($0) else { return false }
                return date > entry.createdAt
            } ?? messages.endIndex
            messages.insert(message, at: insertionIndex)
        }

        guard messages != snapshot.conversation.messages else { return snapshot }
        var result = snapshot
        result.conversation.messages = messages
        return result
    }

    private static func optimisticMessageMetadata(createdAt: Date) -> Data {
        (try? JSONSerialization.data(withJSONObject: [
            "createdAt": DieterTimestamp.string(from: createdAt),
        ])) ?? Data()
    }

    private static func messageCreatedAt(_ message: Dieter_V1_UiMessage) -> Date? {
        guard !message.metadataJson.isEmpty,
              let metadata = try? JSONSerialization.jsonObject(with: message.metadataJson) as? [String: Any],
              let value = metadata["createdAt"] as? String else { return nil }
        return DieterTimestamp.date(from: value)
    }
}
