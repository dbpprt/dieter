import DieterClientAPI
import DieterCore
import Foundation
import GRPCCore
import Testing

@testable import DieterPlatform

struct DieterPlatformTests {
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
}
