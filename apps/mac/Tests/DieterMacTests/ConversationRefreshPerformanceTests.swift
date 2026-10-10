import DieterAPI
import SharedCore
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
        snapshot.detail.card.seenResponseSeq = Int64(sequence)
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

@Test @MainActor func duplicateConversationSlicesDoNotRebuildTheTimeline() {
    let core = ScriptedCoreClient()
    let model = ConversationModel()
    model.core = core
    model.selectedChatID = "card"
    model.observe("card")
    defer { model.observe(nil) }
    let first = fixtureMessage("message")
    core.emitConversation("card") {
        $0.conversation.lastSeq = 10
        $0.messages = [first]
    }
    let revision = model.conversationPresentationRevision
    for _ in 0..<100 {
        core.emitConversation("card") {
            $0.conversation.lastSeq = 10
            $0.messages = [first]
        }
    }
    #expect(model.conversationPresentationRevision == revision)
    core.emitConversation("card") {
        $0.conversation.lastSeq = 11
        $0.messages = [first, fixtureMessage("reply", role: "assistant")]
    }
    #expect(model.conversationPresentationRevision == revision + 1)
    #expect(model.conversationMessages.map(\.id) == ["message", "reply"])
}

@Test @MainActor func cachedConversationStaysReadableWhileRefreshing() {
    let core = ScriptedCoreClient()
    let model = ConversationModel()
    model.core = core
    model.selectedChatID = "card"
    model.observe("card")
    defer { model.observe(nil) }
    let message = fixtureMessage("cached")
    core.emitConversation("card") {
        $0.messages = [message]
        $0.syncing = true
    }
    #expect(model.conversationSyncing)
    #expect(!model.conversationLoading)
    #expect(model.conversationMessages == [message])
    let revision = model.conversationPresentationRevision
    core.emitConversation("card") {
        $0.messages = [message]
        $0.refreshedAtMillis = 1
    }
    #expect(!model.conversationSyncing)
    #expect(model.conversationLastRefreshedAt != nil)
    #expect(model.conversationMessages == [message])
    #expect(model.conversationPresentationRevision == revision)
}
