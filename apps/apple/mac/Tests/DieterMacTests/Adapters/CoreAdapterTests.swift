import DieterClientAPI
import DieterCore
import Foundation
import Testing

@testable import DieterMacKit

/// The Mac's adapters over the core: keyed delta folds, the session file
/// store, and slice subscriptions.
struct CoreAdapterTests {
    struct Item: Equatable {
        let id: String
        let value: Int
    }

    @Test func keyedDeltasFoldExactlyAsTheCoreComputesThem() {
        let base = [Item(id: "a", value: 1), Item(id: "b", value: 1), Item(id: "c", value: 1)]
        // Upserts replace in place and append new keys; removals drop keys.
        #expect(
            KeyedList.apply(
                base, upserted: [Item(id: "b", value: 2), Item(id: "d", value: 1)], removed: ["a"], order: nil,
                key: \.id)
                == [Item(id: "b", value: 2), Item(id: "c", value: 1), Item(id: "d", value: 1)])
        // An explicit order wins and ignores unknown keys.
        #expect(
            KeyedList.apply(base, upserted: [], removed: [], order: ["c", "x", "a"], key: \.id)
                == [Item(id: "c", value: 1), Item(id: "a", value: 1)])
    }

    @Test func secureStoreKeepsSessionsInOneUserOnlyFile() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "dieter-secure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "gateway-sessions.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(["https://gateway.getdieter.com:443": "stored-token"]).write(to: file)

        let store = CoreFileSecureStore(fileURL: file)
        #expect(store.read(key: "https://gateway.getdieter.com:443") == "stored-token")
        store.write(key: "http://127.0.0.1:4242", value: "local-token")
        store.delete(key: "https://gateway.getdieter.com:443")
        let saved = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
        #expect(saved == ["http://127.0.0.1:4242": "local-token"])
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        store.delete(key: "missing")
        #expect(store.read(key: "http://127.0.0.1:4242") == "local-token")
    }

    @MainActor
    @Test func aLostUpdateResetsAndResubscribes() {
        let core = ScriptedCoreClient()
        var received: [UInt64] = []
        var resets = 0
        let subscription = SliceSubscription(
            client: core, slice: .workspace, onReset: { resets += 1 }, onUpdate: { received.append($0.sequence) })
        core.emit(.workspace) { $0.workspace = ClientWorkspaceSlice() }
        core.emit(.workspace) { $0.workspaceDelta = ClientWorkspaceDelta() }
        core.emit(.workspace, skipSequence: true) { $0.workspaceDelta = ClientWorkspaceDelta() }
        #expect(received == [1, 2])
        #expect(resets == 1)
        #expect(subscription.resubscriptions == 1)
        // The fresh subscription starts again at one.
        core.emit(.workspace) { $0.workspace = ClientWorkspaceSlice() }
        #expect(received.last == 1)
        subscription.close()
    }

    @MainActor
    @Test func aBurstOfUpdatesIsAppliedInOrderAndSettledOnce() {
        let core = ScriptedCoreClient()
        var received: [UInt64] = []
        var settled: [[UInt64]] = []
        var resets = 0
        let subscription = SliceSubscription(
            client: core, slice: .workspace, onReset: { resets += 1 }, onSettled: { settled.append(received) },
            onUpdate: { received.append($0.sequence) })
        core.emit(.workspace, latest: false) { $0.workspace = ClientWorkspaceSlice() }
        core.emit(.workspace, latest: false) { $0.workspaceDelta = ClientWorkspaceDelta() }
        #expect(received == [1, 2])
        #expect(settled.isEmpty, "a queued update follows")
        core.emit(.workspace) { $0.workspaceDelta = ClientWorkspaceDelta() }
        #expect(settled == [[1, 2, 3]])
        // A gap behind an unsettled update settles what was applied before the reset.
        core.emit(.workspace, latest: false) { $0.workspaceDelta = ClientWorkspaceDelta() }
        core.emit(.workspace, skipSequence: true) { $0.workspaceDelta = ClientWorkspaceDelta() }
        #expect(received == [1, 2, 3, 4])
        #expect(settled == [[1, 2, 3], [1, 2, 3, 4]])
        #expect(resets == 1)
        subscription.close()
    }
}
