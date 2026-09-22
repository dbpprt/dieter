import DieterAPI
import Testing
@testable import DieterMac

@Test @MainActor func conversationMetadataDoesNotRebuildTimeline() {
    let model = ConversationModel()
    var snapshot = Dieter_V1_ConversationSnapshot()
    snapshot.detail.card.id = "card"
    snapshot.conversation.cardID = "card"
    var message = Dieter_V1_UiMessage()
    message.id = "message"
    snapshot.conversation.messages = [message]
    model.conversation = snapshot
    let revision = model.conversationPresentationRevision
    for sequence in 1...1_000 {
        snapshot.conversation.lastSeq = Int64(sequence)
        snapshot.detail.card.commentCount = Int32(sequence)
        model.conversation = snapshot
    }
    #expect(model.conversationPresentationRevision == revision)
    snapshot.conversation.taskPlans = [Dieter_V1_TaskPlan()]
    model.conversation = snapshot
    #expect(model.conversationPresentationRevision == revision + 1)
    snapshot.conversation.subagents = [Dieter_V1_Subagent()]
    model.conversation = snapshot
    #expect(model.conversationPresentationRevision == revision + 2)
    snapshot.conversation.queue = [Dieter_V1_QueuedMessage()]
    model.conversation = snapshot
    #expect(model.conversationPresentationRevision == revision + 3)
}

@Test @MainActor func duplicateConversationFramesDoNotPersistAgain() async {
    let model = ConversationModel()
    model.selectedChatID = "card"
    var snapshot = Dieter_V1_ConversationSnapshot()
    snapshot.detail.card.id = "card"
    snapshot.conversation.cardID = "card"
    snapshot.conversation.lastSeq = 10
    var writes = 0
    model.onSnapshot = { _, _, _ in writes += 1 }
    var update = Dieter_V1_ConversationUpdate()
    update.snapshot = snapshot
    await model.applyConversationUpdate(update, cardID: "card")
    let revision = model.conversationPresentationRevision
    model.conversationLastRefreshedAt = .distantPast
    for _ in 0..<100 {
        await model.applyConversationUpdate(update, cardID: "card")
    }
    #expect(writes == 1)
    #expect(model.conversationPresentationRevision == revision)
    #expect(model.conversationLastRefreshedAt != .distantPast)
    update.snapshot.conversation.lastSeq = 11
    await model.applyConversationUpdate(update, cardID: "card")
    #expect(writes == 2)
}
