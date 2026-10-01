import DieterAPI
import DieterShared
import Foundation
import SwiftProtobuf
import Synchronization

/// A command or observation the shared core refused, classified so the UI can
/// retry, ask to sign in, or ask for an update.
package struct CoreFailure: Error, LocalizedError, Equatable, Sendable {
    package let kind: ClientFailure.Kind
    package let message: String

    package init(kind: ClientFailure.Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    package init(_ failure: ClientFailure) {
        self.init(kind: failure.kind, message: failure.message)
    }

    package var errorDescription: String? { message }
}

/// The shared core as the app sees it: commands in, slice updates out. The
/// live client wraps DieterShared; tests script a fake with the same contract.
package protocol CoreClient: AnyObject, Sendable {
    /// Runs `command`; throws `CoreFailure` when the core refuses it.
    func dispatch(_ command: ClientCommand) async throws -> ClientResult

    /// Delivers `slice` updates for `scope` on the main actor, in order, until
    /// the observation closes. The first update is a snapshot.
    @MainActor func observe(
        _ slice: ClientSlice, scope: String, onUpdate: @escaping @MainActor (ClientUpdate) -> Void
    ) -> CoreObservation
}

extension CoreClient {
    /// Dispatches a command built in place. It runs on the caller's actor, so
    /// the builder never crosses an isolation boundary.
    @discardableResult
    nonisolated(nonsending) package func dispatch(_ build: (inout ClientCommand) -> Void) async throws -> ClientResult {
        var command = ClientCommand()
        build(&command)
        return try await dispatch(command)
    }
}

/// An open observation. Closing it (or releasing it) stops delivery at once,
/// including updates already queued for the main actor.
package final class CoreObservation: Sendable {
    private let onClose: Mutex<(@Sendable () -> Void)?>

    package init(_ onClose: @escaping @Sendable () -> Void) {
        self.onClose = Mutex(onClose)
    }

    package func close() {
        onClose.withLock { current -> (@Sendable () -> Void)? in
            defer { current = nil }
            return current
        }?()
    }

    deinit { close() }
}

// The Kotlin façade confines all work to the core's single dispatcher; its
// entry points (dispatch, observe, start, shutdown) may be called from any thread.
extension DieterShared: @unchecked @retroactive Sendable {}

/// DieterShared behind `CoreClient`: commands and slices cross as protobuf bytes.
package final class LiveCoreClient: CoreClient {
    package let shared: DieterShared

    package init(shared: DieterShared) {
        self.shared = shared
    }

    package func dispatch(_ command: ClientCommand) async throws -> ClientResult {
        let encoded: Data = try command.serializedData()
        let reply = try ClientReply(serializedBytes: try await shared.dispatch(command: encoded))
        switch reply.reply {
        case .result(let result): return result
        case .failure(let failure): throw CoreFailure(failure)
        case nil: throw CoreFailure(kind: .invalid, message: "The core returned an empty reply.")
        }
    }

    @MainActor
    package func observe(
        _ slice: ClientSlice, scope: String, onUpdate: @escaping @MainActor (ClientUpdate) -> Void
    ) -> CoreObservation {
        let relay = UpdateRelay(onUpdate)
        let subscription = shared.observe(slice: Int32(slice.rawValue), scope: scope, observer: relay)
        let box = NativeCallback(subscription)
        return CoreObservation {
            relay.stop()
            box.value.close()
        }
    }
}

/// Decodes updates on the core's thread and delivers them to the main actor in
/// order. After `stop()`, queued updates are dropped.
private final class UpdateRelay: NSObject, SharedObserver, Sendable {
    private let deliver: @MainActor (ClientUpdate) -> Void
    private let active = Mutex(true)

    init(_ deliver: @escaping @MainActor (ClientUpdate) -> Void) {
        self.deliver = deliver
    }

    func stop() { active.withLock { $0 = false } }

    func update(bytes: Data) {
        guard active.withLock({ $0 }), let update = try? ClientUpdate(serializedBytes: bytes) else { return }
        let box = NativeCallback(update)
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                guard active.withLock({ $0 }) else { return }
                deliver(box.value)
            }
        }
    }
}

/// One slice observation that checks the per-subscription sequence. A gap
/// (a dropped or undecodable update) resets the owner's state and resubscribes,
/// so keyed deltas are never applied to a stale base.
@MainActor
package final class SliceSubscription {
    private let client: CoreClient
    private let slice: ClientSlice
    private let scope: String
    private let onUpdate: @MainActor (ClientUpdate) -> Void
    private let onReset: @MainActor () -> Void
    private var observation: CoreObservation?
    private var expected: UInt64 = 1
    package private(set) var resubscriptions = 0

    package init(
        client: CoreClient, slice: ClientSlice, scope: String = "",
        onReset: @escaping @MainActor () -> Void = {},
        onUpdate: @escaping @MainActor (ClientUpdate) -> Void
    ) {
        self.client = client
        self.slice = slice
        self.scope = scope
        self.onUpdate = onUpdate
        self.onReset = onReset
        start()
    }

    private func start() {
        expected = 1
        observation = client.observe(slice, scope: scope) { [weak self] update in self?.receive(update) }
    }

    private func receive(_ update: ClientUpdate) {
        guard update.sequence == expected else {
            resubscribe()
            return
        }
        expected += 1
        onUpdate(update)
    }

    package func resubscribe() {
        observation?.close()
        resubscriptions += 1
        onReset()
        start()
    }

    package func close() {
        observation?.close()
        observation = nil
    }

    deinit { observation?.close() }
}

/// Folds keyed deltas exactly as the core computes them (`Keyed.apply`).
package enum KeyedList {
    package static func apply<Item>(
        _ base: [Item], upserted: [Item], removed: [String], order: [String]?, key: (Item) -> String
    ) -> [Item] {
        let removedSet = Set(removed)
        var items: [String: Item] = [:]
        var sequence: [String] = []
        for item in base where !removedSet.contains(key(item)) {
            let id = key(item)
            if items.updateValue(item, forKey: id) == nil { sequence.append(id) }
        }
        for item in upserted {
            let id = key(item)
            if items.updateValue(item, forKey: id) == nil { sequence.append(id) }
        }
        return (order ?? sequence).compactMap { items[$0] }
    }
}
