import CryptoKit
import DieterAPI
import Foundation
import GRPCCore
import SwiftProtobuf

package protocol SharedKVConnection: Sendable {
    func listKV(_ request: Dieter_V1_KVListRequest) async throws -> Dieter_V1_KVPage
    func getKV(_ request: Dieter_V1_KVRef) async throws -> Dieter_V1_KVEntry
    func putKV(_ request: Dieter_V1_KVPutRequest) async throws -> Dieter_V1_KVEntry
    func deleteKV(_ request: Dieter_V1_KVDeleteRequest) async throws -> Dieter_V1_KVEntry
    func moveKV(_ request: Dieter_V1_KVMoveRequest) async throws -> Dieter_V1_KVEntry
    func watchKV(_ request: Dieter_V1_KVWatchRequest, receive: @escaping @Sendable (Dieter_V1_KVFrame) async -> Void)
        async throws
}

extension DieterRPC: SharedKVConnection {
    package func listKV(_ request: Dieter_V1_KVListRequest) async throws -> Dieter_V1_KVPage {
        try await service.listKV(request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }
    package func getKV(_ request: Dieter_V1_KVRef) async throws -> Dieter_V1_KVEntry {
        try await service.getKV(request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }
    package func putKV(_ request: Dieter_V1_KVPutRequest) async throws -> Dieter_V1_KVEntry {
        try await service.putKV(request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }
    package func deleteKV(_ request: Dieter_V1_KVDeleteRequest) async throws -> Dieter_V1_KVEntry {
        try await service.deleteKV(request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }
    package func moveKV(_ request: Dieter_V1_KVMoveRequest) async throws -> Dieter_V1_KVEntry {
        try await service.moveKV(request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }
    package func watchKV(
        _ request: Dieter_V1_KVWatchRequest, receive: @escaping @Sendable (Dieter_V1_KVFrame) async -> Void
    ) async throws {
        try await service.watchKV(request: .init(message: request)) { response in
            for try await frame in response.messages { try Task.checkCancellation(); await receive(frame) }
        }
    }
}

package struct SharedPosition: Codable, Equatable, Sendable {
    package var parent: String
    package var rank: String
    package init(parent: String, rank: String) { self.parent = parent; self.rank = rank }
}

/// One account subscription and durable outbox. A prepared request is immutable
/// until success or a definite rejection; uncertain requests remain daemon-bound.
@MainActor package final class SharedKV {
    struct Intent: Codable {
        var id = UUID().uuidString
        var key: String
        var value: Data?
        var deleted = false
        var parent: String?
        var after = ""
        var before = ""
        var requiresExisting = false
        var prepared: Data?
        var daemonID: String?
    }
    struct Cache: Codable {
        var entries: [String: Data] = [:]
        var pending: [Intent] = []
    }
    package private(set) var account = ""
    package private(set) var pendingCount = 0
    package private(set) var error: String?
    package var changed: (@MainActor () -> Void)?
    private let defaults: UserDefaults
    private let root: URL?
    private let namespace: String
    private var cache = Cache()
    private var rpc: (any SharedKVConnection)?
    private var daemonID = ""
    private var task: Task<Void, Never>?
    private var delivery: Task<Void, Never>?
    private var generation = 0
    private var replacement: [String: Data] = [:]
    package init(defaults: UserDefaults, root: URL? = nil, namespace: String = "navigation") {
        self.defaults = defaults; self.root = root; self.namespace = namespace
        account = defaults.string(forKey: "DieterSharedKV.activeAccount") ?? ""
        daemonID = defaults.string(forKey: "DieterSharedKV.activeDaemon") ?? ""
        cache = readCache().flatMap { try? JSONDecoder().decode(Cache.self, from: $0) } ?? Cache()
        pendingCount = cache.pending.count
    }
    deinit { task?.cancel(); delivery?.cancel() }
    private var cacheKey: String {
        "DieterSharedKV." + account + "." + namespace + (account == "local" ? "." + daemonID : "")
    }
    private var cacheURL: URL? {
        let digest = SHA256.hash(data: Data(cacheKey.utf8)).map { String(format: "%02x", $0) }.joined()
        return root?.appending(path: digest + ".json")
    }
    private func readCache() -> Data? {
        if let cacheURL { return try? Data(contentsOf: cacheURL) }
        return defaults.data(forKey: cacheKey)
    }
    private var entries: [String: Dieter_V1_KVEntry] {
        cache.entries.compactMapValues { try? Dieter_V1_KVEntry(serializedBytes: $0) }
    }
    package var values: [String: Data] {
        var result = entries.filter { !$0.value.deleted }.mapValues(\.valueJson)
        for intent in cache.pending {
            if intent.deleted {
                result.removeValue(forKey: intent.key)
            } else if let parent = intent.parent {
                let positions = result.compactMapValues { try? JSONDecoder().decode(SharedPosition.self, from: $0) }
                let prefix = String(intent.key.prefix { $0 != "." }) + "."
                let left =
                    positions[intent.after]?.rank
                    ?? (intent.before.isEmpty
                        ? positions.filter {
                            $0.key != intent.key && $0.key.hasPrefix(prefix) && $0.value.parent == parent
                        }.values.map(\.rank).max() ?? "" : "")
                let right = positions[intent.before]?.rank ?? ""
                let rank =
                    Self.between(left, right) + intent.id.lowercased().replacingOccurrences(of: "-", with: "") + "h"
                result[intent.key] = try? JSONEncoder().encode(SharedPosition(parent: parent, rank: rank))
            } else if !intent.requiresExisting || entries[intent.key]?.deleted != true {
                result[intent.key] = intent.value
            }
        }
        return result
    }
    private static func between(_ left: String, _ right: String) -> String {
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let a = Array(left); var b = Array(right); var prefix = ""
        for index in 0..<512 {
            let low = index < a.count ? digits.firstIndex(of: a[index]) ?? 0 : 0
            let high = index < b.count ? digits.firstIndex(of: b[index]) ?? 35 : 35
            if high - low > 1 { return prefix + String(digits[(low + high) / 2]) }
            prefix.append(digits[low]); if high > low { b = [] }
        }
        return left + "h"
    }
    package func put<T: Encodable>(_ key: String, _ value: T, requiresExisting: Bool = false) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        guard data.count <= 32 << 10 else {
            error = "Shared values must be at most 32 KiB."; changed?(); return
        }
        enqueue(Intent(key: key, value: data, requiresExisting: requiresExisting))
    }
    package func delete(_ key: String) { enqueue(Intent(key: key, deleted: true)) }
    package func move(_ key: String, parent: String = "", after: String = "", before: String = "") {
        enqueue(Intent(key: key, parent: parent, after: after, before: before))
    }
    private func enqueue(_ intent: Intent) {
        guard !account.isEmpty else {
            error = "Connect to an account before organizing navigation."; changed?(); return
        }
        guard cache.pending.count < 1024 else {
            error = "Navigation has 1,024 pending edits. Reconnect before editing more."; changed?(); return
        }
        cache.pending.append(intent)
        guard save() else { cache.pending.removeLast(); pendingCount = cache.pending.count; changed?(); return }
        changed?(); flush()
    }
    @discardableResult private func save() -> Bool {
        pendingCount = cache.pending.count
        defaults.set(account, forKey: "DieterSharedKV.activeAccount")
        defaults.set(daemonID, forKey: "DieterSharedKV.activeDaemon")
        if !account.isEmpty, let data = try? JSONEncoder().encode(cache) {
            do {
                if let root, let cacheURL {
                    try FileManager.default.createDirectory(
                        at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try data.write(to: cacheURL, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
                } else {
                    defaults.set(data, forKey: cacheKey)
                }
            } catch {
                self.error = "Could not persist navigation: \(error.localizedDescription)"
                delivery?.cancel(); rpc = nil; changed?(); return false
            }
        }
        return true
    }
    package func clearAccount() {
        bind(nil); account = ""; cache = Cache(); pendingCount = 0; error = nil; save(); changed?()
    }
    package func bind(_ connection: (any SharedKVConnection)?) {
        generation += 1; let token = generation
        task?.cancel(); delivery?.cancel(); delivery = nil; rpc = connection
        guard let connection else { return }
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && token == self.generation {
                do {
                    var request = Dieter_V1_KVListRequest(); request.namespace = self.namespace
                    let info = try await connection.listKV(request)
                    guard token == self.generation else { return }
                    if self.account != info.account || (info.account == "local" && self.daemonID != info.daemonID) {
                        self.account = info.account; self.daemonID = info.daemonID
                        self.cache =
                            self.readCache().flatMap { try? JSONDecoder().decode(Cache.self, from: $0) } ?? Cache()
                        self.changed?()
                        // Invalidate in-flight deliveries before subscribing to
                        // another account, even when the transport object survived.
                        self.bind(connection)
                        return
                    }
                    self.daemonID = info.daemonID
                    var watch = Dieter_V1_KVWatchRequest(); watch.namespace = self.namespace;
                    watch.account = info.account
                    // Replace only at caughtUp, so paginated bootstrap never flashes partial layouts.
                    try await connection.watchKV(watch) { [weak self] frame in
                        await self?.receive(frame, generation: token)
                    }
                } catch {
                    guard token == self.generation && !Task.isCancelled else { return }
                    self.error = String(describing: error); self.changed?()
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    private func receive(_ frame: Dieter_V1_KVFrame, generation token: Int) {
        guard token == generation, frame.account == account else { return }
        if frame.reset { replacement = [:] }
        for entry in frame.entries { replacement[entry.key] = try? entry.serializedData() }
        guard frame.caughtUp else { return }
        for (key, raw) in replacement {
            let incoming = try? Dieter_V1_KVEntry(serializedBytes: raw)
            let old = cache.entries[key].flatMap { try? Dieter_V1_KVEntry(serializedBytes: $0) }
            // Keep read-your-writes while a different replica catches up.
            let covers =
                old?.versions.allSatisfy { prior in
                    incoming?.versions.contains { next in
                        prior.clock.allSatisfy { actor, count in (next.clock[actor] ?? 0) >= count }
                    } == true
                } ?? true
            if covers { cache.entries[key] = raw }
        }
        error = nil; guard save() else { return }; changed?(); flush()
    }
    private static func covers(_ incoming: Dieter_V1_KVEntry?, _ prior: Dieter_V1_KVEntry) -> Bool {
        prior.versions.allSatisfy { old in
            incoming?.versions.contains { next in
                old.clock.allSatisfy { actor, count in (next.clock[actor] ?? 0) >= count }
            } == true
        }
    }
    private static func anchors(
        _ rpc: any SharedKVConnection, ref: Dieter_V1_KVRef, parent: String, after: String, before: String
    ) async throws -> (String, String) {
        func rank(_ key: String) async throws -> String? {
            guard !key.isEmpty else { return nil }
            var request = ref; request.key = key
            do {
                let entry = try await rpc.getKV(request)
                guard !entry.deleted,
                    let position = try? JSONDecoder().decode(SharedPosition.self, from: entry.valueJson),
                    position.parent == parent
                else { return nil }
                return position.rank
            } catch let e as RPCError where e.code == .notFound { return nil }
        }
        let left = try await rank(after), right = try await rank(before)
        if let left, let right, left >= right { return ("", before) }
        return (left == nil ? "" : after, right == nil ? "" : before)
    }
    private func flush() {
        guard delivery == nil, let rpc, !cache.pending.isEmpty else { return }
        let token = generation
        delivery = Task { [weak self] in
            guard let self else { return }
            defer { if token == self.generation { self.delivery = nil } }
            while !Task.isCancelled && token == self.generation && !self.cache.pending.isEmpty {
                do {
                    var intent = self.cache.pending[0]
                    if let accepting = intent.daemonID, accepting != self.daemonID {
                        self.error = "A pending navigation edit awaits its accepting machine."; self.changed?(); return
                    }
                    if intent.prepared == nil {
                        var ref = Dieter_V1_KVRef(); ref.namespace = self.namespace; ref.key = intent.key;
                        ref.account = self.account
                        var current: Dieter_V1_KVEntry?
                        do { current = try await rpc.getKV(ref) } catch let e as RPCError where e.code == .notFound {}
                        guard token == self.generation else { return }
                        if let prior = self.cache.entries[intent.key].flatMap({
                            try? Dieter_V1_KVEntry(serializedBytes: $0)
                        }), !Self.covers(current, prior) {
                            self.error = "Waiting for this machine to receive earlier navigation edits.";
                            self.changed?()
                            try await Task.sleep(for: .seconds(1)); continue
                        }
                        if intent.requiresExisting && (current == nil || current?.deleted == true) {
                            self.cache.pending.removeFirst(); guard self.save() else { return }; self.changed?();
                            continue
                        }
                        if let parent = intent.parent {
                            var request = Dieter_V1_KVMoveRequest(); request.ref = ref; request.parent = parent
                            let anchors = try await Self.anchors(
                                rpc, ref: ref, parent: parent, after: intent.after, before: intent.before)
                            guard token == self.generation else { return }
                            request.afterKey = anchors.0; request.beforeKey = anchors.1
                            request.expectedRevision = current?.revision ?? ""; request.operationID = intent.id;
                            request.daemonID = self.daemonID
                            intent.prepared = try request.serializedData()
                        } else if intent.deleted {
                            var request = Dieter_V1_KVDeleteRequest(); request.ref = ref
                            request.expectedRevision = current?.revision ?? ""; request.operationID = intent.id;
                            request.daemonID = self.daemonID
                            intent.prepared = try request.serializedData()
                        } else {
                            var request = Dieter_V1_KVPutRequest(); request.ref = ref;
                            request.valueJson = intent.value ?? Data()
                            request.expectedRevision = current?.revision ?? ""; request.operationID = intent.id;
                            request.daemonID = self.daemonID
                            intent.prepared = try request.serializedData()
                        }
                        intent.daemonID = self.daemonID; self.cache.pending[0] = intent;
                        guard self.save() else { return }
                    }
                    let result: Dieter_V1_KVEntry
                    if intent.parent != nil {
                        result = try await rpc.moveKV(.init(serializedBytes: intent.prepared!))
                    } else if intent.deleted {
                        result = try await rpc.deleteKV(.init(serializedBytes: intent.prepared!))
                    } else {
                        result = try await rpc.putKV(.init(serializedBytes: intent.prepared!))
                    }
                    guard token == self.generation else { return }
                    let prior = self.cache.entries[result.key].flatMap { try? Dieter_V1_KVEntry(serializedBytes: $0) }
                    if prior == nil || Self.covers(result, prior!) {
                        self.cache.entries[result.key] = try result.serializedData()
                    }
                    self.cache.pending.removeFirst(); self.error = nil; guard self.save() else { return };
                    self.changed?()
                } catch let e as RPCError where e.code == .aborted {
                    guard token == self.generation else { return }
                    self.cache.pending[0].prepared = nil; self.cache.pending[0].daemonID = nil
                    self.cache.pending[0].id = UUID().uuidString; guard self.save() else { return }
                    try? await Task.sleep(for: .milliseconds(250))
                } catch {
                    guard token == self.generation else { return }
                    self.error = String(describing: error); self.changed?()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }
}
