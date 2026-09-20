import DieterAPI
import DieterClient
import Foundation
import GRPCCore
import Testing

actor KVFixture: SharedKVConnection {
    var account: String
    var entries: [String: Dieter_V1_KVEntry] = [:]
    var receipts: [String: Dieter_V1_KVEntry] = [:]
    var loseNextResponse = false
    var holdNextResponse = false
    var heldResponse: CheckedContinuation<Void, Never>?
    var calls = 0
    init(account: String = "test-account") { self.account = account }
    func loseResponse() { loseNextResponse = true }
    func holdResponse() { holdNextResponse = true }
    func releaseResponse() { heldResponse?.resume(); heldResponse = nil }
    func changeAccount(_ value: String) { account = value; entries = [:]; receipts = [:] }
    func listKV(_ request: Dieter_V1_KVListRequest) async throws -> Dieter_V1_KVPage {
        var page = Dieter_V1_KVPage(); page.account = account; page.daemonID = "fixture";
        page.entries = Array(entries.values); return page
    }
    func getKV(_ request: Dieter_V1_KVRef) async throws -> Dieter_V1_KVEntry {
        guard let value = entries[request.key] else { throw RPCError(code: .notFound, message: "missing") };
        return value
    }
    func putKV(_ request: Dieter_V1_KVPutRequest) async throws -> Dieter_V1_KVEntry {
        if let previous = receipts[request.operationID] { return previous }
        if request.expectedRevision != entries[request.ref.key]?.revision ?? "" {
            throw RPCError(code: .aborted, message: "stale")
        }
        calls += 1
        var entry = Dieter_V1_KVEntry(); entry.namespace = "navigation"; entry.key = request.ref.key;
        entry.valueJson = request.valueJson; entry.revision = "r\(calls)"
        var version = Dieter_V1_PeerVersion(); version.clock = ["fixture": UInt64(calls)];
        version.valueJson = request.valueJson; entry.versions = [version]
        entries[entry.key] = entry; receipts[request.operationID] = entry
        if loseNextResponse {
            loseNextResponse = false; throw RPCError(code: .unavailable, message: "lost acknowledgement")
        }
        if holdNextResponse {
            holdNextResponse = false
            await withCheckedContinuation { heldResponse = $0 }
        }
        return entry
    }
    func deleteKV(_ request: Dieter_V1_KVDeleteRequest) async throws -> Dieter_V1_KVEntry {
        var put = Dieter_V1_KVPutRequest(); put.ref = request.ref; put.expectedRevision = request.expectedRevision;
        put.operationID = request.operationID
        var value = try await putKV(put); value.deleted = true; value.versions[0].deleted = true
        entries[value.key] = value; receipts[request.operationID] = value; return value
    }
    func moveKV(_ request: Dieter_V1_KVMoveRequest) async throws -> Dieter_V1_KVEntry {
        var put = Dieter_V1_KVPutRequest(); put.ref = request.ref; put.expectedRevision = request.expectedRevision;
        put.operationID = request.operationID
        put.valueJson = try JSONEncoder().encode(SharedPosition(parent: request.parent, rank: "h\(calls)"));
        return try await putKV(put)
    }
    func watchKV(_ request: Dieter_V1_KVWatchRequest, receive: @escaping @Sendable (Dieter_V1_KVFrame) async -> Void)
        async throws
    {
        var reset = true
        while !Task.isCancelled {
            guard request.account == account else {
                throw RPCError(code: .failedPrecondition, message: "account changed")
            }
            var frame = Dieter_V1_KVFrame(); frame.account = account; frame.daemonID = "fixture"; frame.reset = reset;
            frame.caughtUp = true; frame.entries = Array(entries.values)
            await receive(frame); reset = false; try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@Test @MainActor func sharedKVAccountChangeRejectsLateAcknowledgementOnTheSameConnection() async throws {
    let name = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let server = KVFixture(); let client = SharedKV(defaults: defaults)
    defer { client.bind(nil) }
    client.bind(server)
    try await eventually { client.account == "test-account" }
    await server.holdResponse()
    client.put("projects-folder.old.name", "Old account")
    for _ in 0..<500 {
        if await server.heldResponse != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await server.heldResponse != nil)
    await server.changeAccount("new-account")
    try await eventually { client.account == "new-account" }
    client.put("projects-folder.new.name", "New account")
    await server.releaseResponse()
    try await eventually { client.pendingCount == 0 && client.values["projects-folder.new.name"] != nil }
    #expect(client.values["projects-folder.old.name"] == nil)
    #expect(await server.entries["projects-folder.new.name"] != nil)
    let restored = SharedKV(defaults: defaults)
    #expect(restored.account == "new-account")
    #expect(restored.values["projects-folder.old.name"] == nil)
}

@MainActor private func eventually(_ predicate: () -> Bool) async throws {
    for _ in 0..<500 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
    Issue.record("shared state did not converge")
}

@Test @MainActor func sharedKVClientsConvergePersistOfflineEditsAndRetryLostAcknowledgements() async throws {
    let oneName = UUID().uuidString, twoName = UUID().uuidString
    let oneDefaults = try #require(UserDefaults(suiteName: oneName));
    let twoDefaults = try #require(UserDefaults(suiteName: twoName))
    defer { oneDefaults.removePersistentDomain(forName: oneName); twoDefaults.removePersistentDomain(forName: twoName) }
    let server = KVFixture(); let one = SharedKV(defaults: oneDefaults); let two = SharedKV(defaults: twoDefaults)
    defer { one.bind(nil); two.bind(nil) }
    one.bind(server); two.bind(server)
    try await eventually { one.account == "test-account" && two.account == one.account }
    await server.loseResponse()
    one.put("projects-folder.f.name", "Research")
    try await eventually { one.pendingCount == 0 && two.values["projects-folder.f.name"] != nil }
    #expect(await server.calls == 1)
    one.bind(nil); one.put("projects-folder.f.expanded", false)
    let restored = SharedKV(defaults: oneDefaults)
    defer { restored.bind(nil) }
    #expect(restored.pendingCount == 1)
    #expect(restored.values["projects-folder.f.expanded"] == Data("false".utf8))
    restored.bind(server)
    try await eventually {
        restored.pendingCount == 0 && two.values["projects-folder.f.expanded"] == Data("false".utf8)
    }
    // An offline rename cannot revive a folder deleted before reconnect.
    restored.bind(nil); restored.put("projects-folder.f.name", "Offline rename", requiresExisting: true)
    two.delete("projects-folder.f.name")
    try await eventually { two.pendingCount == 0 && two.values["projects-folder.f.name"] == nil }
    restored.bind(server)
    try await eventually { restored.pendingCount == 0 && restored.values["projects-folder.f.name"] == nil }
    restored.bind(KVFixture(account: "another-account"))
    try await eventually { restored.account == "another-account" }
    #expect(restored.values.isEmpty)
    restored.clearAccount()
    #expect(SharedKV(defaults: oneDefaults).values.isEmpty)
}
