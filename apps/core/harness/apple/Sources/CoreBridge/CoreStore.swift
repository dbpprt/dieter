import DieterMessages
import DieterShared
import Foundation
import Observation
import SwiftProtobuf

/// A command the shared core rejected; `kind` tells the UI what to offer.
public struct SharedFailure: Error, Sendable {
    public let kind: ClientFailure.Kind
    public let message: String
}

/// What SwiftUI observes. The shared Kotlin core owns routing, sync, the
/// outbox, and conversations; this adapter dispatches encoded commands and
/// folds encoded slices on the main actor. It holds no business logic.
@MainActor
@Observable
public final class SharedStore {
    public private(set) var session = ClientSessionSlice()
    public private(set) var workspace = ClientWorkspaceSlice()
    public private(set) var conversations: [String: ClientConversationSlice] = [:]
    /// Updates that arrived out of order; the store resubscribed.
    public private(set) var resubscriptions = 0

    @ObservationIgnored private let core: DieterShared
    @ObservationIgnored private var subscriptions: [String: SharedSubscription] = [:]
    @ObservationIgnored private var sequences: [String: UInt64] = [:]

    public init(stateDirectory: URL, clientVersion: String, secureStore: MemorySecureStore = MemorySecureStore()) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        core = DieterShared(
            configuration: SharedConfiguration(
                stateDirectory: stateDirectory.path, clientVersion: clientVersion, oauthRedirectUri: "dieter-harness://oauth/callback",
                clientIdPrefix: "harness", legacyClientId: nil, includeLoopbackRoutes: false, compactTranscripts: false),
            extensions: SharedExtensions(
                rpc: GRPCBridge(), secureStore: secureStore, settings: MemorySettings(), http: URLSessionHttp(),
                signatures: CryptoKitSignatures(), logger: PrintLogger(), notifications: nil)
        )
        subscribe(.session, scope: "")
        subscribe(.workspace, scope: "")
    }

    public var clientID: String { core.clientId }

    public func start() { core.start() }

    @discardableResult
    public func dispatch(_ command: ClientCommand) async throws -> ClientResult {
        let reply = try ClientReply(serializedBytes: try await core.dispatch(command: command.serializedData()))
        switch reply.reply {
        case .result(let result): return result
        case .failure(let failure): throw SharedFailure(kind: failure.kind, message: failure.message)
        case nil: throw SharedFailure(kind: .invalid, message: "The core sent an empty reply.")
        }
    }

    public func observeConversation(_ cardID: String) { subscribe(.conversation, scope: cardID) }

    public func stopObservingConversation(_ cardID: String) {
        subscriptions.removeValue(forKey: key(.conversation, cardID))?.close()
        conversations[cardID] = nil
    }

    public func shutdown() async throws {
        subscriptions.values.forEach { $0.close() }
        subscriptions.removeAll()
        try await core.shutdown()
    }

    private func key(_ slice: ClientSlice, _ scope: String) -> String { "\(slice.rawValue)|\(scope)" }

    private func subscribe(_ slice: ClientSlice, scope: String) {
        let key = key(slice, scope)
        subscriptions.removeValue(forKey: key)?.close()
        sequences[key] = 0
        subscriptions[key] = core.observe(slice: Int32(slice.rawValue), scope: scope, observer: UpdateRelay(store: self))
    }

    fileprivate func apply(_ update: ClientUpdate) {
        let key = key(update.slice, update.scope)
        guard subscriptions[key] != nil else { return }
        guard update.sequence == (sequences[key] ?? 0) + 1 else {
            // A missed delta: start over from a fresh snapshot.
            resubscriptions += 1
            return subscribe(update.slice, scope: update.scope)
        }
        sequences[key] = update.sequence
        switch update.value {
        case .session(let slice): session = slice
        case .workspace(let slice): workspace = slice
        case .workspaceDelta(let delta):
            workspace.projects = delta.projects
            workspace.boards = delta.boards
            workspace.cards = Keyed.apply(workspace.cards, delta.upsertedCards, delta.removedCardIds, delta.orderChanged ? delta.cardOrder : nil, id: \.id)
            workspace.pendingCardIds = delta.pendingCardIds
            workspace.loaded = delta.loaded
            workspace.projectReplicas = delta.projectReplicas
        case .conversation(let slice): conversations[update.scope] = slice
        case .conversationDelta(let delta):
            guard var slice = conversations[update.scope] else { return subscribe(.conversation, scope: update.scope) }
            slice.card = delta.card
            slice.conversation = delta.conversation
            slice.messages = Keyed.apply(slice.messages, delta.upsertedMessages, delta.removedMessageIds, delta.orderChanged ? delta.messageOrder : nil, id: \.id)
            slice.loading = delta.loading
            slice.syncing = delta.syncing
            slice.error = delta.error
            slice.pending = delta.pending
            slice.hasEarlier_p = delta.hasEarlier_p
            slice.loadingEarlier = delta.loadingEarlier
            slice.browsingEarlier = delta.browsingEarlier
            conversations[update.scope] = slice
        default: break
        }
    }
}

/// Keyed deltas, applied exactly as the core computes them.
enum Keyed {
    static func apply<T>(_ base: [T], _ upserted: [T], _ removed: [String], _ order: [String]?, id: KeyPath<T, String>) -> [T] {
        let removed = Set(removed)
        var items: [String: T] = [:]
        var keys: [String] = []
        for item in base where !removed.contains(item[keyPath: id]) {
            items[item[keyPath: id]] = item
            keys.append(item[keyPath: id])
        }
        for item in upserted {
            if items.updateValue(item, forKey: item[keyPath: id]) == nil { keys.append(item[keyPath: id]) }
        }
        return (order ?? keys).compactMap { items[$0] }
    }
}

/// Receives encoded updates on a Kotlin thread and decodes them before the
/// hop; DispatchQueue.main keeps their order.
private final class UpdateRelay: NSObject, SharedObserver, @unchecked Sendable {
    private weak var store: SharedStore?
    init(store: SharedStore) { self.store = store }

    func update(bytes: Data) {
        guard let update = try? ClientUpdate(serializedBytes: bytes) else { return }
        DispatchQueue.main.async { [weak store] in MainActor.assumeIsolated { store?.apply(update) } }
    }
}
