import DieterAPI
import Foundation
import Testing
@testable import DieterMac

private actor ReceiptFixture: ConversationRPC {
    var receipts: [Int64] = []
    func markConversationRead(cardID: String, responseSeq: Int64) async throws -> Dieter_V1_Card {
        receipts.append(responseSeq)
        var card = Dieter_V1_Card()
        card.id = cardID
        card.scope = "chat"
        card.responseSeq = responseSeq
        card.responseMessageID = "reply"
        card.seenResponseSeq = responseSeq
        return card
    }
    func conversation(cardID: String, limit: Int32, before: Int32?) async throws -> Dieter_V1_ConversationSnapshot {
        throw CancellationError()
    }
    func watchConversation(
        cardID: String, after: Int64,
        receive: @escaping @Sendable (Dieter_V1_ConversationUpdate) async -> Void
    ) async throws {
        throw CancellationError()
    }
}

@Test @MainActor func readReceiptRequiresLoadedReplyAndCurrentSelection() async {
    let rpc = ReceiptFixture()
    let model = ConversationModel()
    model.bind(client: rpc, endpointID: "machine")
    model.selectedChatID = "chat"
    var snapshot = Dieter_V1_ConversationSnapshot()
    snapshot.detail.card.id = "chat"
    snapshot.detail.card.scope = "chat"
    snapshot.detail.card.responseSeq = 40
    snapshot.detail.card.responseMessageID = "reply"
    model.conversation = snapshot
    await model.markResponseSeen()
    #expect(await rpc.receipts.isEmpty)
    var reply = Dieter_V1_UiMessage()
    reply.id = "reply"
    reply.role = "assistant"
    snapshot.conversation.messages = [reply]
    model.conversation = snapshot
    // Directory metadata can announce completion before the final transcript frame arrives.
    snapshot.conversation.lastSeq = 39
    model.conversation = snapshot
    await model.markResponseSeen()
    #expect(await rpc.receipts.isEmpty)
    snapshot.conversation.lastSeq = 40
    model.conversation = snapshot
    model.browsingEarlierHistory = true
    await model.markResponseSeen()
    #expect(await rpc.receipts.isEmpty)
    model.browsingEarlierHistory = false
    model.selectedChatID = "other"
    await model.markResponseSeen()
    #expect(await rpc.receipts.isEmpty)
    model.selectedChatID = "chat"
    await model.markResponseSeen()
    await model.markResponseSeen()
    #expect(await rpc.receipts == [40])
    #expect(model.conversation?.detail.card.seenResponseSeq == 40)
}
