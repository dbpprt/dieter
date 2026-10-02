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

    @Test func sharedRulesAnswerSynchronouslyFromAnyThread() async {
        #expect(SharedRules.shared.bytes(count: 1536) == "1.5 KB")
        let now: Int64 = 1_000_000_000_000
        #expect(SharedRules.shared.compactAge(sinceMillis: 0, nowMillis: now) == "")
        await MainActor.run {
            #expect(SharedRules.shared.compactAge(sinceMillis: now - 5 * 60_000, nowMillis: now) == "5m")
        }
        // Rules hold no state, so concurrent callers never wait on the core.
        let answers = await withTaskGroup(of: String.self) { group in
            for index in 0..<16 {
                group.addTask { SharedRules.shared.bytes(count: Int64(index) * 1024) }
            }
            return await group.reduce(into: [String]()) { $0.append($1) }
        }
        #expect(Set(answers).count == 16)
    }

    @Test func sharedRulesReturnEncodedClientMessages() throws {
        let palette = try ClientLabelPalette(serializedBytes: SharedRules.shared.labelPalette())
        #expect(palette.swatches.count == 10)
        #expect(palette.swatches.first?.name == "Ruby" && palette.swatches.first?.hex == "#d95c68")
        // Highlights are packed (start, length, kind) triples in UTF-16, shifted by the offset.
        let highlights = try ClientSyntaxHighlights(
            serializedBytes: SharedRules.shared.syntaxHighlights(text: "let 💡 = 42", path: "a.swift", offset: 10))
        #expect(highlights.spans.count % 3 == 0)
        let starts = stride(from: 0, to: highlights.spans.count, by: 3).map { highlights.spans[$0] }
        #expect(starts.contains(10))
        #expect(starts.contains(10 + Int32(("let 💡 = " as NSString).length)))
        let cadence = try ClientScheduleCadence(
            serializedBytes: SharedRules.shared.scheduleCadence(cron: "0 9 * * 1-5"))
        #expect(cadence.kind == .weekdays && cadence.summary == "Weekdays at 09:00")
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
