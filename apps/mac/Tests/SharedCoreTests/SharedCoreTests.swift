import DieterAPI
import DieterShared
import Foundation
import GRPCCore
import Testing

@testable import SharedCore

struct SharedCoreTests {
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

    @Test func transportFailuresReachTheCoreAsRetryableStatuses() {
        #expect(CoreRpcBridge.status(of: RPCError(code: .notFound, message: "missing")) == (5, "missing"))
        #expect(
            CoreRpcBridge.status(
                of: RPCError(code: .unimplemented, message: "No messages received, exactly one was expected.")
            ).0 == 14)
        #expect(CoreRpcBridge.status(of: RPCError(code: .unimplemented, message: "not here")).0 == 12)
        #expect(CoreRpcBridge.status(of: CancellationError()).0 == 1)
        #expect(CoreRpcBridge.status(of: RuntimeError(code: .clientIsStopped, message: "stopped")).0 == 14)
        #expect(CoreRpcBridge.status(of: POSIXError(.ECONNRESET)).0 == 14)
    }

    @Test func sharedKvCacheNamesMatchTheLegacyApp() {
        #expect(
            MacLegacyInputs.sharedKvFile(account: "github:1", daemonID: "d_1")
                == "6898f6a880b11ea21829883a42cf4f4d218d72979201d72dceb005f620d62860.json")
        #expect(
            MacLegacyInputs.sharedKvFile(account: "local", daemonID: "d_1")
                == "b9f1b58a33d2cc28070b4bdfc05425acc7113770d1867dd69b445ee442ee1eb0.json")
    }

    @Test func secureStoreSharesTheLegacySessionFile() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "dieter-secure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "gateway-sessions.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(["https://gateway.getdieter.com:443": "legacy-token"]).write(to: file)

        let store = CoreFileSecureStore(fileURL: file)
        #expect(store.read(key: "https://gateway.getdieter.com:443") == "legacy-token")
        store.write(key: "http://127.0.0.1:4242", value: "local-token")
        store.delete(key: "https://gateway.getdieter.com:443")
        let saved = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
        #expect(saved == ["http://127.0.0.1:4242": "local-token"])
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        store.delete(key: "missing")
        #expect(store.read(key: "http://127.0.0.1:4242") == "local-token")
    }

    @Test func legacyInputsReadEveryMacSourceWithoutChangingIt() throws {
        let suite = "SharedCoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appending(path: "dieter-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appending(path: "Dieter")
        try FileManager.default.createDirectory(
            at: legacy.appending(path: "shared-kv"), withIntermediateDirectories: true)
        let credentials = root.appending(path: "gateway-sessions.json")
        try Data(#"{"https://gateway.getdieter.com:443":"t"}"#.utf8).write(to: credentials)
        try Data(#"{"version":1,"revision":3,"entries":[]}"#.utf8).write(
            to: legacy.appending(path: "pending-commands.json"))
        let cache = legacy.appending(path: "shared-kv").appending(
            path: MacLegacyInputs.sharedKvFile(account: "github:1", daemonID: "d_1"))
        try Data(#"{"entries":{},"pending":[]}"#.utf8).write(to: cache)
        defaults.set(Data(#"[{"host":"gateway.getdieter.com"}]"#.utf8), forKey: "DieterEndpoints")
        defaults.set("github:1", forKey: "DieterSharedKV.activeAccount")
        defaults.set("d_1", forKey: "DieterSharedKV.activeDaemon")
        defaults.set(["project|p1": "t1"], forKey: "DieterSelectedTerminalsByTarget")
        defaults.set(false, forKey: "DieterNotifications")
        defaults.set("project", forKey: "DieterConversationCreationWorkspaceMode")

        let input = MacLegacyInputs.read(defaults: defaults, legacyDirectory: legacy, credentialsFile: credentials)
        #expect(input.endpointsJson == #"[{"host":"gateway.getdieter.com"}]"#)
        #expect(input.activeEndpointJson == nil)
        #expect(input.tokensJson == #"{"https://gateway.getdieter.com:443":"t"}"#)
        #expect(input.pendingCommandsJson?.contains(#""revision":3"#) == true)
        #expect(input.sharedKvAccount == "github:1")
        #expect(input.sharedKvDaemon == "d_1")
        #expect(input.sharedKvJson == #"{"entries":{},"pending":[]}"#)
        #expect(input.terminalSelections == ["project|p1": "t1"])
        #expect(input.notificationsEnabled?.boolValue == false)
        #expect(input.creationWorkspaceMode == "project")
        #expect(!input.isIos)
        #expect(FileManager.default.fileExists(atPath: cache.path), "reading never deletes legacy state")
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
}
