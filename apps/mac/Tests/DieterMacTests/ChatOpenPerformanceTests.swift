import DieterAPI
import Testing
@testable import DieterMac

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

@Test @MainActor func liveChatDirectoryNavigationSkipsRefreshAndLoadsArchivedChatsOnRequest() async throws {
    let store = DieterStore(restoreSync: false)
    store.foldFixture(Dieter_V1_State())
    store.phase = .connected(version: "fixture")
    let before = store.chatsRequestGeneration
    await store.openChats()
    await store.ensureChatDirectory(includeArchived: false)
    #expect(store.chatsRequestGeneration == before)
    #expect(!store.chatsLoading)
    store.globalSyncing = true
    #expect(!store.hasLiveChatDirectory)
    store.globalSyncing = false
    // Archived chats are not part of the live workspace and are listed on request.
    await store.ensureChatDirectory(includeArchived: true)
    #expect(store.chatsRequestGeneration > before)
}
