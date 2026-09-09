import DieterAPI
import Foundation
import Testing
@testable import DieterMac

private actor ConversationReadFixture: ConversationRPC {
    var requests: [String] = []
    var pending: [Int: CheckedContinuation<Dieter_V1_ConversationSnapshot, Never>] = [:]
    var count: Int { requests.count }
    func conversation(cardID: String, limit: Int32, before: Int32?) async throws -> Dieter_V1_ConversationSnapshot {
        let index = requests.count; requests.append(cardID)
        return await withCheckedContinuation { pending[index] = $0 }
    }
    func finish(_ index: Int, text: String) {
        var snapshot = Dieter_V1_ConversationSnapshot()
        snapshot.detail.card.id = requests[index]; snapshot.conversation.cardID = requests[index]
        var message = Dieter_V1_UiMessage(); message.id = text; snapshot.conversation.messages = [message]
        pending.removeValue(forKey: index)?.resume(returning: snapshot)
    }
    func watchConversation(
        cardID: String, after: Int64, receive: @escaping @Sendable (Dieter_V1_ConversationUpdate) async -> Void
    ) async throws {
        try await Task.sleep(nanoseconds: 3_600_000_000_000)
    }
}

@Test @MainActor func conversationABASelectionRejectsTheOriginalReadAndCacheEffect() async throws {
    let rpc = ConversationReadFixture(), model = ConversationModel()
    model.bind(client: rpc, endpointID: "machine")
    var cached: [String] = []
    model.onSnapshot = { value, _, _ in cached.append(value.conversation.messages.first?.id ?? "") }
    model.selectedChatID = "A"
    let first = Task { await model.fetchConversation(cardID: "A", chat: true, rpc: rpc) }
    for _ in 0..<1_000 {
        if await rpc.count == 1 { break }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    model.conversationSelectionGeneration &+= 1; model.selectedChatID = "B"
    model.conversationSelectionGeneration &+= 1; model.selectedChatID = "A"
    model.conversationRead.cancel()
    let replacement = Task { await model.fetchConversation(cardID: "A", chat: true, rpc: rpc) }
    for _ in 0..<1_000 {
        if await rpc.count == 2 { break }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(await rpc.count == 2)
    await rpc.finish(1, text: "new"); await replacement.value
    await rpc.finish(0, text: "old"); await first.value
    #expect(model.conversationMessages.map(\.id) == ["new"])
    #expect(cached == ["new"])
    model.bind(client: nil, endpointID: "machine")
}

private actor EarlierHistoryFixture: ConversationRPC {
    func conversation(cardID: String, limit: Int32, before: Int32?) async throws -> Dieter_V1_ConversationSnapshot {
        var snapshot = Dieter_V1_ConversationSnapshot()
        var oldest = Dieter_V1_UiMessage(); oldest.id = "oldest"
        snapshot.conversation.messages = [oldest]
        snapshot.page.start = 0; snapshot.page.total = 2_002; snapshot.page.hasMore_p = false
        return snapshot
    }
    func watchConversation(
        cardID: String, after: Int64, receive: @escaping @Sendable (Dieter_V1_ConversationUpdate) async -> Void
    ) async throws {
        throw CancellationError()
    }
}

@Test @MainActor func historyBudgetPagesBackWithoutJoiningAcrossAGapAndCanReturnToLive() async {
    let model = ConversationModel(), rpc = EarlierHistoryFixture()
    model.bind(client: rpc, endpointID: "machine")
    model.selectedChatID = "card"
    var live = Dieter_V1_ConversationSnapshot()
    var latest = Dieter_V1_UiMessage(); latest.id = "live"
    live.conversation.messages = [latest]
    live.page.start = 2_001; live.page.total = 2_002; live.page.hasMore_p = true
    model.conversation = live
    model.olderConversationMessages = (0..<2_000).map {
        var message = Dieter_V1_UiMessage(); message.id = "history-\($0)"; return message
    }
    model.conversationHistoryStart = 1; model.conversationHistoryHasMore = true
    #expect(await model.loadEarlierMessages())
    #expect(model.browsingEarlierHistory)
    #expect(model.conversationMessages.count == 2_000)
    #expect(model.conversationMessages.first?.id == "oldest")
    #expect(!model.conversationMessages.contains { $0.id == "live" })
    var frame = Dieter_V1_ConversationUpdate()
    frame.removedMessageIds = ["live"]
    latest.id = "new-live"; frame.changedMessages = [latest]
    model.apply(frame)
    #expect(model.conversationMessages.first?.id == "oldest")
    #expect(model.conversationMessages.count == 2_000)
    model.returnToLatest()
    #expect(!model.browsingEarlierHistory)
    #expect(model.conversationMessages.map(\.id) == ["new-live"])
    #expect(model.conversationHistoryHasMore)
    model.bind(client: nil, endpointID: "machine")
}
