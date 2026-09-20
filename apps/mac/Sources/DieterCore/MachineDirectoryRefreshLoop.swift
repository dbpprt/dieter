import Foundation

/// Presence must not wait for route negotiation, snapshots, or provider quotas.
/// Idle gateway heartbeats arrive every 20 seconds; polling every 5 seconds
/// leaves room before the 30-second presence lease expires.
package enum MachineDirectoryRefreshLoop {
    package static func run(
        refreshImmediately: Bool,
        presenceInterval: TimeInterval = 5,
        directoryInterval: TimeInterval = 15,
        refreshPresence: @escaping @Sendable () async -> Void,
        refreshDirectory: @escaping @Sendable () async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    await refreshPresence()
                    do { try await DieterTaskSleep.seconds(presenceInterval) } catch { return }
                }
            }
            group.addTask {
                if refreshImmediately && !Task.isCancelled { await refreshDirectory() }
                while !Task.isCancelled {
                    do { try await DieterTaskSleep.seconds(directoryInterval) } catch { return }
                    guard !Task.isCancelled else { return }
                    await refreshDirectory()
                }
            }
        }
    }
}
