import DieterClient
import Foundation
import Observation

@MainActor @Observable
final class DurableOutbox {
    @ObservationIgnored var workerTask: Task<Void, Never>?
    @ObservationIgnored var workerGeneration: UInt64 = 0
    private(set) var entries: [DieterOutboxEntry] = []
    private(set) var error: String?
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private let journal: OutboxJournal

    init(journal: OutboxJournal) { self.journal = journal }

    func restore() async throws { accept(try await journal.load()) }

    @discardableResult
    func update<Result: Sendable>(
        _ operation: @escaping @Sendable (inout [DieterOutboxEntry]) throws -> Result
    ) async throws -> Result {
        do {
            let (snapshot, result) = try await journal.transaction(operation)
            accept(snapshot)
            return result
        } catch {
            self.error = "Could not save pending messages: \(error.localizedDescription)"
            throw error
        }
    }

    func enqueue(_ entry: DieterOutboxEntry) async throws {
        try await update { entries in
            guard !entries.contains(where: { $0.commandID == entry.commandID }) else { return }
            entries.append(entry)
        }
    }

    private func accept(_ snapshot: OutboxJournal.Snapshot) {
        guard snapshot.revision >= revision else { return }
        revision = snapshot.revision
        if entries != snapshot.entries { entries = snapshot.entries }
        error = nil
    }
}
