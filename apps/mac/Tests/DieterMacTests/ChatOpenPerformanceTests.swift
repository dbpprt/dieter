import DieterAPI
import SharedCore
import Testing
@testable import DieterMac

@Test @MainActor func reselectingAllChatsKeepsTheOpenConversationAndItsGeneration() async {
    let store = DieterStore(liveEnvironment: false)
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

@Test @MainActor func chatNavigationLeavesArchivedChatsToTheCoresList() async throws {
    let core = ScriptedCoreClient()
    let store = DieterStore(core: core, liveEnvironment: false)
    store.foldFixture(Dieter_V1_State())
    store.phase = .connected(version: "fixture")
    let before = store.chatsRequestGeneration
    await store.openChats()
    #expect(store.chatsRequestGeneration == before)
    // The list takes commands once the core has shown it; earlier ones wait.
    store.chatsList.attach(core)
    store.chatsList.showArchived(true)
    #expect(!core.commands.contains { $0.chats.showArchived.on })
    core.emit(.chats, scope: "mac-chats") { $0.chats = ClientChatsSlice() }
    for _ in 0..<200 where !core.commands.contains(where: { $0.chats.showArchived.on }) {
        try await Task.sleep(for: .milliseconds(5))
    }
    let sent = try #require(core.commands.first { $0.chats.showArchived.on })
    #expect(sent.chats.scope == "mac-chats")
    #expect(store.chatsRequestGeneration == before, "archived chats load in the core")
}
