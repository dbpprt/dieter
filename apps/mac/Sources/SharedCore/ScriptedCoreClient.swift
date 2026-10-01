import DieterAPI
import Foundation

/// A scripted core for previews and tests: it records dispatched commands,
/// answers them with a handler, and lets the test emit slice updates. It has
/// the live client's delivery contract (in-order, main actor, sequence per
/// subscription), so adapters behave as they do against DieterShared.
@MainActor
package final class ScriptedCoreClient: CoreClient {
    private struct Observer {
        let slice: ClientSlice
        let scope: String
        let deliver: @MainActor (ClientUpdate) -> Void
        var sequence: UInt64 = 0
    }

    private var observers: [Int: Observer] = [:]
    private var nextObserver = 0
    /// Every command dispatched so far, in order.
    package private(set) var commands: [ClientCommand] = []
    /// Answers a command; the default acknowledges it with `Done`.
    package var handler: @MainActor (ClientCommand) throws -> ClientResult = { _ in .with { $0.done = ClientDone() } }
    /// Answers a command asynchronously, e.g. to hold a request open; it
    /// replaces `handler` when set.
    package var asyncHandler: (@MainActor (ClientCommand) async throws -> ClientResult)?

    package nonisolated init() {}

    package nonisolated func dispatch(_ command: ClientCommand) async throws -> ClientResult {
        try await respond(to: command)
    }

    private func respond(to command: ClientCommand) async throws -> ClientResult {
        commands.append(command)
        if let asyncHandler { return try await asyncHandler(command) }
        return try handler(command)
    }

    package func observe(
        _ slice: ClientSlice, scope: String, onUpdate: @escaping @MainActor (ClientUpdate) -> Void
    ) -> CoreObservation {
        let id = nextObserver
        nextObserver += 1
        observers[id] = Observer(slice: slice, scope: scope, deliver: onUpdate)
        return CoreObservation { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.observers[id] = nil }
            } else {
                Task { @MainActor in self?.observers[id] = nil }
            }
        }
    }

    /// Whether anything observes `slice` in `scope`.
    package func isObserved(_ slice: ClientSlice, scope: String = "") -> Bool {
        observers.values.contains { $0.slice == slice && $0.scope == scope }
    }

    /// Sends `value` to every observer of `slice` in `scope`, numbering it per
    /// subscription. `skipSequence` simulates a lost update.
    package func emit(
        _ slice: ClientSlice, scope: String = "", skipSequence: Bool = false, _ value: (inout ClientUpdate) -> Void
    ) {
        for id in observers.keys.sorted() {
            guard var observer = observers[id], observer.slice == slice, observer.scope == scope else { continue }
            observer.sequence += skipSequence ? 2 : 1
            observers[id] = observer
            var update = ClientUpdate()
            update.slice = slice
            update.scope = scope
            update.sequence = observer.sequence
            value(&update)
            observer.deliver(update)
        }
    }
}
