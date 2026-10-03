import Foundation

/// Reduces the daemon's potentially high-frequency terminal frames away from
/// the main actor and publishes at most once per display interval. Reset
/// frames publish immediately because they establish the base for later bytes.
package actor TerminalOutputAccumulator {
    package typealias Publish = @MainActor @Sendable (String, TerminalScreenState) -> Void

    private let frameIntervalNanoseconds: UInt64
    private let sleep: @Sendable (UInt64) async throws -> Void
    private var screens: [String: TerminalScreenState] = [:]
    private var scheduledFlushes: [String: Task<Void, Never>] = [:]

    package init(
        frameIntervalNanoseconds: UInt64 = 16_000_000,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.frameIntervalNanoseconds = frameIntervalNanoseconds
        self.sleep = sleep
    }

    package func enqueue(
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

/// How much terminal output the app keeps per terminal for replay.
package let terminalClientBufferLimit = 2 * 1_024 * 1_024
package struct TerminalScreenState: Equatable, Sendable {
    package private(set) var chunks: [Data] = []
    package private(set) var byteCount = 0
    package var revision = 0
    package var resetRevision = 0

    package init() {}

    /// Compatibility accessor for persistence fixtures and diagnostics. The
    /// live renderer consumes `chunks` directly so normal terminal updates do
    /// not flatten and recopy the retained replay buffer.
    package var data: Data {
        get {
            guard chunks.count != 1 else { return chunks[0] }
            return chunks.reduce(into: Data(capacity: byteCount)) { $0.append($1) }
        }
        set {
            chunks = newValue.isEmpty ? [] : [newValue]
            byteCount = newValue.count
        }
    }

    package mutating func replace(with data: Data) {
        chunks = data.isEmpty ? [] : Self.chunked(data)
        byteCount = data.count
    }

    @discardableResult
    package mutating func append(_ data: Data, limit: Int) -> Bool {
        guard !data.isEmpty else { return false }
        var remaining = data[...]
        if var tail = chunks.last, tail.count < Self.chunkSize {
            chunks.removeLast()
            let count = min(Self.chunkSize - tail.count, remaining.count)
            tail.append(contentsOf: remaining.prefix(count))
            chunks.append(tail)
            remaining = remaining.dropFirst(count)
        }
        while !remaining.isEmpty {
            let count = min(Self.chunkSize, remaining.count)
            chunks.append(Data(remaining.prefix(count)))
            remaining = remaining.dropFirst(count)
        }
        byteCount += data.count
        return trim(to: limit)
    }

    private mutating func trim(to limit: Int) -> Bool {
        guard byteCount > limit else { return false }
        var discard = byteCount - max(0, limit)
        while let first = chunks.first, discard >= first.count {
            discard -= first.count
            chunks.removeFirst()
        }
        if discard > 0, let first = chunks.first {
            chunks[0] = Data(first.dropFirst(discard))
        }
        byteCount = max(0, limit)
        return true
    }

    private static let chunkSize = 64 * 1_024

    private static func chunked(_ data: Data) -> [Data] {
        stride(from: 0, to: data.count, by: chunkSize).map { offset in
            Data(data[offset..<min(data.count, offset + chunkSize)])
        }
    }
}

package enum TerminalScreenReducer {
    package static func applying(
        data: Data,
        screenReset: Bool,
        to current: TerminalScreenState,
        limit: Int = terminalClientBufferLimit
    ) -> TerminalScreenState {
        var result = current
        if screenReset {
            result.replace(with: data)
            result.resetRevision += 1
        } else {
            if result.append(data, limit: limit) { result.resetRevision += 1 }
        }
        if screenReset, result.byteCount > limit {
            result.data = Data(result.data.suffix(limit))
            result.resetRevision += 1
        }
        result.revision += 1
        return result
    }
}
