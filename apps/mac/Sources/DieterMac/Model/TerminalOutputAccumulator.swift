import Foundation

/// Reduces the daemon's potentially high-frequency terminal frames away from
/// the main actor and publishes at most once per display interval. Reset
/// frames publish immediately because they establish the base for later bytes.
actor TerminalOutputAccumulator {
    typealias Publish = @MainActor @Sendable (String, TerminalScreenState) -> Void

    private let frameIntervalNanoseconds: UInt64
    private let sleep: @Sendable (UInt64) async throws -> Void
    private var screens: [String: TerminalScreenState] = [:]
    private var scheduledFlushes: [String: Task<Void, Never>] = [:]

    init(
        frameIntervalNanoseconds: UInt64 = 16_000_000,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.frameIntervalNanoseconds = frameIntervalNanoseconds
        self.sleep = sleep
    }

    func enqueue(
        terminalID: String,
        data: Data,
        screenReset: Bool,
        current: TerminalScreenState,
        publish: @escaping Publish
    ) async {
        let next = TerminalScreenReducer.applying(
            data: data,
            screenReset: screenReset,
            to: screens[terminalID] ?? current
        )
        screens[terminalID] = next

        if screenReset {
            scheduledFlushes.removeValue(forKey: terminalID)?.cancel()
            await publish(terminalID, next)
            return
        }
        guard scheduledFlushes[terminalID] == nil else { return }
        scheduledFlushes[terminalID] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sleep(self.frameIntervalNanoseconds)
            } catch {
                return
            }
            await self.flush(terminalID: terminalID, publish: publish)
        }
    }

    private func flush(terminalID: String, publish: Publish) async {
        scheduledFlushes.removeValue(forKey: terminalID)
        guard let screen = screens[terminalID] else { return }
        await publish(terminalID, screen)
    }
}
