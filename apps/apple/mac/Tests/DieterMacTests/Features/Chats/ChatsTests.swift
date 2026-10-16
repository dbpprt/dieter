import DieterAPI
import Testing
@testable import DieterMacKit

/// Pinned chat drag payloads and restoring the last used chat.
struct ChatsTests {
    @Test func pinnedChatDragPayloadRejectsOtherStringDrops() {
        let payload = PinnedChatDragPayload(chatID: "c_first")
        #expect(PinnedChatDragPayload(payload.encoded) == payload)
        #expect(PinnedChatDragPayload("not-a-pinned-chat") == nil)
        #expect(PinnedChatDragPayload("dieter:pinned-chat:") == nil)
    }

    @Test @MainActor func openingAllChatsRestoresTheLastUsedActiveChat() async {
        let store = DieterStore()
        var project = Dieter_V1_Project()
        project.id = "p_project"
        var firstChat = Dieter_V1_Card()
        firstChat.id = "c_first"
        firstChat.projectID = project.id
        firstChat.scope = "chat"
        var lastUsedChat = Dieter_V1_Card()
        lastUsedChat.id = "c_last"
        lastUsedChat.projectID = project.id
        lastUsedChat.scope = "chat"

        store.projectDirectory = [project.id: project]
        store.chats = [firstChat, lastUsedChat]

        await store.openConversation(cardID: lastUsedChat.id, chat: true)
        store.closeConversation()
        store.section = .settings

        await store.openChats()

        #expect(store.section == .chats)
        #expect(store.selectedChatID == lastUsedChat.id)
        #expect(store.lastUsedChatID == lastUsedChat.id)
    }

    @Test @MainActor func chatUnreadFollowsTheCardAcrossRepeatedReads() {
        let store = DieterStore(liveEnvironment: false)
        var chat = Dieter_V1_Card()
        chat.id = "c_unread"
        chat.scope = "chat"
        chat.responseSeq = 2
        chat.seenResponseSeq = 1
        // Rows ask on every render; a kept answer must follow the card.
        #expect(store.isChatUnread(chat))
        #expect(store.isChatUnread(chat))
        chat.seenResponseSeq = 2
        #expect(!store.isChatUnread(chat))
        chat.responseSeq = 3
        #expect(store.isChatUnread(chat))
    }
}
