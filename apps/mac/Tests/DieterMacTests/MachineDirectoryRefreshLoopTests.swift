import DieterCore
import Synchronization
import Testing

@Test func presenceRefreshContinuesWhileMachineReadIsStalled() async throws {
    let state = Mutex((presence: 0, directoryStarted: false, directoryCancelled: false))
    let loop = Task {
        await MachineDirectoryRefreshLoop.run(
            refreshImmediately: true,
            presenceInterval: 0.01,
            directoryInterval: 0.01,
            refreshPresence: { state.withLock { $0.presence += 1 } },
            refreshDirectory: {
                state.withLock { $0.directoryStarted = true }
                do { try await DieterTaskSleep.seconds(60) } catch { state.withLock { $0.directoryCancelled = true } }
            }
        )
    }
    defer { loop.cancel() }
    for _ in 0..<200 {
        if state.withLock({ $0.directoryStarted && $0.presence >= 3 }) { break }
        try await DieterTaskSleep.milliseconds(10)
    }
    #expect(state.withLock { $0.directoryStarted && $0.presence >= 3 })
    loop.cancel()
    await loop.value
    #expect(state.withLock { $0.directoryCancelled })
    let count = state.withLock { $0.presence }
    try await DieterTaskSleep.milliseconds(30)
    #expect(state.withLock { $0.presence } == count)
}
