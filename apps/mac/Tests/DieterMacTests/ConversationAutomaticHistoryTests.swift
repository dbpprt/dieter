import DieterAPI
import Foundation
import Testing
@testable import DieterMac

private func automaticHistoryMessage(_ index: Int) -> Dieter_V1_UiMessage {
    var message = Dieter_V1_UiMessage()
    message.id = "message-\(index)"
    message.role = "user"
    var part = Dieter_V1_MessagePart()
    part.type = "text"
    part.text = "Message \(index)"
    message.parts = [part]
    return message
}

private actor AutomaticHistoryRPC: ConversationRPC {
    var requests: [Int32] = []
    var total = 3_030

    func conversation(cardID: String, limit: Int32, before: Int32?) async throws -> Dieter_V1_ConversationSnapshot {
        let end = min(total, Int(before ?? Int32(total)))
        let start = max(0, end - Int(limit))
        requests.append(Int32(end))
        var snapshot = Dieter_V1_ConversationSnapshot()
        snapshot.conversation.cardID = cardID
        snapshot.conversation.messages = (start..<end).map(automaticHistoryMessage)
        snapshot.page.start = Int32(start)
        snapshot.page.total = Int32(total)
        snapshot.page.hasMore_p = start > 0
        return snapshot
    }

    func watchConversation(
        cardID: String, after: Int64, receive: @escaping @Sendable (Dieter_V1_ConversationUpdate) async -> Void
    ) async throws {}
}

@Test @MainActor func automaticHistoryAdvancesAcrossEvictedNewerPagesWithoutGaps() async {
    let rpc = AutomaticHistoryRPC(), model = ConversationModel()
    model.bind(client: rpc, endpointID: "test")
    model.selectedChatID = "chat"
    var live = Dieter_V1_ConversationSnapshot()
    live.conversation.cardID = "chat"
    live.conversation.messages = (3_000..<3_030).map(automaticHistoryMessage)
    live.page.start = 3_000
    live.page.total = 3_030
    live.page.hasMore_p = true
    model.conversation = live
    model.olderConversationMessages = (400..<2_400).map(automaticHistoryMessage)
    model.conversationHistoryStart = 400
    model.conversationHistoryTotal = 3_030
    model.conversationHistoryHasMore = true
    model.browsingEarlierHistory = true

    #expect(await model.loadLaterMessages())
    #expect(model.conversationHistoryStart == 430)
    #expect(model.conversationMessages.map(\.id) == (430..<2_430).map { "message-\($0)" })
    #expect(model.olderConversationMessages.count == 2_000)
    #expect(model.browsingEarlierHistory)
    for _ in 0..<19 { #expect(await model.loadLaterMessages()) }
    #expect(!model.browsingEarlierHistory)
    #expect(model.conversationMessages.map(\.id) == (1_000..<3_030).map { "message-\($0)" })
    #expect(model.olderConversationMessages.count == 2_000)
    #expect(await rpc.requests == stride(from: Int32(2_430), through: 3_000, by: 30).map { $0 })

    model.returnToLatest()
    #expect(model.olderConversationMessages.isEmpty)
    #expect(model.conversationMessages.map(\.id) == (3_000..<3_030).map { "message-\($0)" })
    #expect(model.conversationHistoryStart == 3_000)
    #expect(model.conversationHistoryHasMore)
    #expect(!(await model.loadLaterMessages()))
}

private actor SuspendedAutomaticHistoryRPC: ConversationRPC {
    var pending: CheckedContinuation<Dieter_V1_ConversationSnapshot, Never>?
    var requested: Bool { pending != nil }
    func conversation(cardID: String, limit: Int32, before: Int32?) async throws -> Dieter_V1_ConversationSnapshot {
        await withCheckedContinuation { pending = $0 }
    }
    func finish() {
        var snapshot = Dieter_V1_ConversationSnapshot()
        snapshot.conversation.messages = (30..<60).map(automaticHistoryMessage)
        snapshot.page.start = 30
        snapshot.page.total = 90
        pending?.resume(returning: snapshot)
        pending = nil
    }
    func watchConversation(
        cardID: String, after: Int64, receive: @escaping @Sendable (Dieter_V1_ConversationUpdate) async -> Void
    ) async throws {}
}

@Test @MainActor func returningToLatestRejectsAnInFlightHistoryPage() async {
    let rpc = SuspendedAutomaticHistoryRPC(), model = ConversationModel()
    model.bind(client: rpc, endpointID: "test")
    model.selectedChatID = "chat"
    var live = Dieter_V1_ConversationSnapshot()
    live.conversation.messages = (60..<90).map(automaticHistoryMessage)
    live.page.start = 60
    live.page.total = 90
    live.page.hasMore_p = true
    model.conversation = live
    model.olderConversationMessages = (0..<30).map(automaticHistoryMessage)
    model.conversationHistoryStart = 0
    model.conversationHistoryTotal = 90
    model.browsingEarlierHistory = true
    let request = Task { await model.loadLaterMessages() }
    for _ in 0..<1_000 {
        if await rpc.requested { break }
        await Task.yield()
    }
    #expect(await rpc.requested)
    #expect(!(await model.loadLaterMessages()))
    model.returnToLatest()
    await rpc.finish()
    #expect(!(await request.value))
    #expect(model.olderConversationMessages.isEmpty)
    #expect(model.conversationMessages == live.conversation.messages)
    #expect(!model.conversationHistoryLoading)
    #expect(!model.browsingEarlierHistory)
}
