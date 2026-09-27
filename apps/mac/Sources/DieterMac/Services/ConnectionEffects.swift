import DieterClient
import DieterCore
import Foundation

/// Owns app-lifetime transport and synchronization tasks. Feature projections stay
/// in their models; AppSession supplies explicit event handlers to these effects.
@MainActor final class ConnectionEffects {
    var connectionTask: Task<Void, Never>?
    var reconnectTask: Task<Void, Never>?
    var directRefreshTask: Task<Void, Never>?
    var syncRecoveryEscalationTask: Task<Void, Never>?
    var machineDirectoryTask: Task<Void, Never>?
    var machinePresenceLeaseTask: Task<Void, Never>?
    var connectionMetadataTask: Task<Void, Never>?
    var syncRestoreTask: Task<Void, Never>?
    var stateTask: Task<Void, Never>?
    var syncTask: Task<Void, Never>?
    var syncLivenessTask: Task<Void, Never>?
    private let clock: ClientClock
    init(clock: ClientClock = .live) { self.clock = clock }

    func cancelConnection() {
        for task in [
            connectionTask, reconnectTask, directRefreshTask, syncRecoveryEscalationTask,
            machineDirectoryTask, machinePresenceLeaseTask, connectionMetadataTask,
            stateTask, syncTask, syncLivenessTask,
        ] { task?.cancel() }
        connectionTask = nil; reconnectTask = nil; directRefreshTask = nil
        syncRecoveryEscalationTask = nil; machineDirectoryTask = nil; machinePresenceLeaseTask = nil
        connectionMetadataTask = nil; stateTask = nil; syncTask = nil; syncLivenessTask = nil
    }

    func runTransport(_ client: DieterRPC, stopped: @escaping (Error, String) -> Void) -> Task<Void, Never> {
        Task {
            do {
                try await client.run()
                guard !Task.isCancelled else { return }
                stopped(
                    NSError(
                        domain: "DieterTransport", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The Dieter connection closed."]), "transport-ended")
            } catch { if !Task.isCancelled { stopped(error, "transport-runner") } }
        }
    }

    func startDirectory(
        refreshImmediately: Bool, presence: @escaping @MainActor @Sendable () async -> Void,
        directory: @escaping @MainActor @Sendable () async -> Void
    ) {
        machineDirectoryTask?.cancel()
        machineDirectoryTask = Task {
            await MachineDirectoryRefreshLoop.run(
                refreshImmediately: refreshImmediately,
                refreshPresence: presence, refreshDirectory: directory)
        }
    }

    func startPresence(expire: @escaping (Date) -> TimeInterval) {
        machinePresenceLeaseTask?.cancel()
        machinePresenceLeaseTask = Task { [clock] in
            while !Task.isCancelled {
                let delay = expire(clock.now())
                do { try await clock.sleep(.seconds(delay)) } catch { return }
            }
        }
    }

    func startLiveness(check: @escaping () -> Bool) {
        syncLivenessTask?.cancel()
        syncLivenessTask = Task { [clock] in
            while !Task.isCancelled {
                do { try await clock.sleep(.seconds(5)) } catch { return }
                guard !Task.isCancelled, !check() else { return }
            }
        }
    }
}
