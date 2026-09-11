import DieterAPI
import Foundation
import GRPCCore

struct OutboxTransport {
    let rpc: any OutboxRPC
    let release: @MainActor () -> Void
}

extension DurableOutbox {
    func start(
        reachable: @escaping @MainActor () -> [String],
        acquire: @escaping @MainActor (String) async throws -> OutboxTransport,
        committed: @escaping @MainActor (DieterOutboxEntry) async -> Void,
        failed: @escaping @MainActor (DieterOutboxEntry, Error) -> Void,
        storageFailed: @escaping @MainActor (Error) -> Void,
        clock: ClientClock = .live
    ) {
        guard workerTask?.isCancelled != false else { return }
        workerGeneration &+= 1
        let generation = workerGeneration
        workerTask = Task { [weak self] in
            guard let self else { return }
            defer {
                // A reconnect can cancel this worker and install its successor
                // before this task observes cancellation. The retired worker
                // must not clear the live worker's reference when it unwinds.
                if OutboxWorkerOwnership.mayClearTask(
                    workerGeneration: generation,
                    currentGeneration: self.workerGeneration
                ) {
                    self.workerTask = nil
                }
            }
            while !Task.isCancelled {
                let reachableEndpointIDs = reachable()
                guard !reachableEndpointIDs.isEmpty else { return }
                guard
                    let index = DieterOutboxPolicy.nextIndex(
                        in: self.entries,
                        endpointIDs: reachableEndpointIDs, now: clock.now()
                    )
                else {
                    guard
                        let delay = DieterOutboxPolicy.nextRetryDelay(
                            in: self.entries,
                            endpointIDs: Set(reachableEndpointIDs), now: clock.now()
                        )
                    else { return }
                    try? await clock.sleep(.seconds(min(0.5, max(0.05, delay))))
                    continue
                }
                var entry = self.entries[index]
                do {
                    let transport = try await acquire(entry.endpointID)
                    defer { transport.release() }
                    guard !Task.isCancelled, self.workerGeneration == generation else { return }
                    let deliveryRPC = transport.rpc
                    switch entry.kind {
                    case .createCard:
                        let request = try Dieter_V1_CreateConversationRequest(serializedBytes: entry.request)
                        let card = try await deliveryRPC.createCard(request)
                        try Self.validateCreation(entry, card: card)
                        entry.serverID = card.id
                    case .createChat:
                        let request = try Dieter_V1_CreateConversationRequest(serializedBytes: entry.request)
                        let card = try await deliveryRPC.createChat(request)
                        try Self.validateCreation(entry, card: card)
                        entry.serverID = card.id
                    case .sendMessage:
                        let request = try Dieter_V1_SendMessageRequest(serializedBytes: entry.request)
                        let response = try await deliveryRPC.sendMessage(request)
                        entry.serverID = response.messageID.isEmpty ? entry.optimisticID : response.messageID
                    }
                    entry.lastError = nil
                    entry.state = .queued
                    entry.nextAttemptAt = nil
                    let delivered = entry
                    try await self.update { entries in
                        guard let index = entries.firstIndex(where: { $0.commandID == delivered.commandID }) else {
                            return
                        }
                        if delivered.kind == .sendMessage {
                            entries.remove(at: index)
                        } else {
                            entries[index] = delivered
                            if let serverID = delivered.serverID {
                                try DieterOutboxPolicy.retargetDependencies(
                                    in: &entries, from: delivered.optimisticID, to: serverID)
                            }
                        }
                    }
                    if !Task.isCancelled, self.workerGeneration == generation { await committed(entry) }
                } catch {
                    guard !DieterRPCFailure.isCancellation(error), self.workerGeneration == generation else { return }
                    entry.attempts += 1
                    entry.lastError = DieterRPCFailure.message(for: error)
                    if DieterRPCFailure.isPermanent(error) {
                        entry.state = .failed
                        entry.nextAttemptAt = nil
                    } else {
                        entry.state = .retrying
                        entry.nextAttemptAt = clock.now().addingTimeInterval(
                            DieterOutboxPolicy.backoff(after: entry.attempts))
                    }
                    let failedEntry = entry
                    do {
                        try await self.update { entries in
                            guard
                                let index = entries.firstIndex(where: {
                                    $0.commandID == failedEntry.commandID && $0.serverID == nil
                                })
                            else { return }
                            entries[index] = failedEntry
                        }
                    } catch {
                        storageFailed(error)
                        return
                    }
                    failed(entry, error)
                }
            }
        }
    }

    private static func validateCreation(_ entry: DieterOutboxEntry, card: Dieter_V1_Card) throws {
        guard DieterOutboxPolicy.creationIsComplete(entry, card: card) else {
            throw RPCError(
                code: .failedPrecondition,
                message:
                    "The conversation was saved, but its first turn was not started. Check the machine's available storage and update its daemon before retrying."
            )
        }
    }

}
