import DieterAPI
import Testing
@testable import DieterMac

@Test @MainActor func liveChatDirectoryNavigationSkipsRefreshAndKeepsOfflineFallback() async throws {
    let store = DieterStore(restoreSync: false)
    store.phase = .connected(version: "fixture")
    store.syncSnapshot = Dieter_V1_GlobalSnapshot()
    let rpc = try DieterRPC(endpoint: store.endpoint)
    rpc.shutdown()
    store.rpc = rpc
    let before = store.chatsRequestGeneration
    await store.openChats()
    await store.ensureChatDirectory(includeArchived: false)
    #expect(store.chatsRequestGeneration == before)
    #expect(!store.chatsLoading)
    store.globalSyncing = true
    #expect(!store.hasLiveChatDirectory)
    store.globalSyncing = false
    await store.ensureChatDirectory(includeArchived: true)
    #expect(store.chatsRequestGeneration > before)
    store.syncSnapshot = nil
    #expect(!store.hasLiveChatDirectory)
}

@Test @MainActor func reselectingAllChatsKeepsTheOpenConversationAndItsGeneration() async {
    let store = DieterStore(restoreSync: false)
    store.section = .chats
    store.selectedChatID = "selected-chat"
    var snapshot = Dieter_V1_ConversationSnapshot()
    snapshot.detail.card.id = "selected-chat"
    snapshot.conversation.cardID = "selected-chat"
    snapshot.conversation.lastSeq = 42
    store.conversation = snapshot
    let generation = store.conversationSelectionGeneration
    await store.openChats()
    #expect(store.selectedChatID == "selected-chat")
    #expect(store.conversation == snapshot)
    #expect(store.conversationSelectionGeneration == generation)
}

private actor StreamFirstFixture: ConversationRPC {
    let delivers: Bool
    var reads = 0
    var afters: [Int64] = []
    init(delivers: Bool) { self.delivers = delivers }
    func snapshot(_ id: String) -> Dieter_V1_ConversationSnapshot {
        var snapshot = Dieter_V1_ConversationSnapshot()
        snapshot.detail.card.id = id
        snapshot.detail.card.commentCount = 1
        snapshot.conversation.cardID = id
        snapshot.conversation.lastSeq = 10
        return snapshot
    }
    func conversation(cardID: String, limit: Int32, before: Int32?) async throws -> Dieter_V1_ConversationSnapshot {
        reads += 1
        return snapshot(cardID)
    }
    func watchConversation(
        cardID: String, after: Int64,
        receive: @escaping @Sendable (Dieter_V1_ConversationUpdate) async -> Void
    ) async throws {
        afters.append(after)
        if delivers {
            var update = Dieter_V1_ConversationUpdate()
            update.snapshot = snapshot(cardID)
            await receive(update)
        }
        try await Task.sleep(for: .seconds(60))
    }
}

@Test @MainActor func streamFirstOpenAvoidsDuplicateReadAndRefreshesCachedComments() async {
    let model = ConversationModel(), rpc = StreamFirstFixture(delivers: true)
    model.bind(client: rpc, endpointID: "fixture")
    model.selectedChatID = "chat"
    model.conversationLoading = true
    var accepted = 0
    model.onAccepted = { _, _ in accepted += 1 }
    var stale = Dieter_V1_ConversationSnapshot()
    stale.detail.card.id = "chat"
    stale.conversation.lastSeq = 10
    model.conversation = stale
    await model.fetchConversation(cardID: "chat", chat: true, rpc: rpc, preferStream: true)
    #expect(await rpc.reads == 0)
    #expect(await rpc.afters == [0])
    #expect(model.conversation?.detail.card.commentCount == 1)
    #expect(!model.conversationSyncing)
    #expect(!model.conversationLoading)
    #expect(accepted == 1)
    model.bind(client: nil, endpointID: "fixture")
}

@Test @MainActor func stalledInitialStreamGetsOneUnaryHedge() async {
    let model = ConversationModel(), rpc = StreamFirstFixture(delivers: false)
    model.bind(client: rpc, endpointID: "fixture")
    model.selectedChatID = "chat"
    await model.fetchConversation(cardID: "chat", chat: true, rpc: rpc, preferStream: true)
    #expect(await rpc.reads == 1)
    #expect(await rpc.afters == [0])
    #expect(model.conversation?.detail.card.id == "chat")
    model.bind(client: nil, endpointID: "fixture")
}
