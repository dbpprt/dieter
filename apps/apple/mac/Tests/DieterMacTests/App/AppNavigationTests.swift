import DieterAPI
import Testing
@testable import DieterMacKit

/// Top-level destinations and opening conversations into the Inbox, a board, or Chats.
struct AppNavigationTests {
    @Test func settingsAreFirstClassNestedNavigationDestinations() {
        #expect(AppSection.allCases.contains(.settings))
        #expect(
            DieterSettingsSection.allCases.map(\.rawValue) == [
                "General", "Browser", "Connection", "Devices", "Usage", "Prompts", "Notifications", "Island",
                "Agents", "Experimental",
            ])
    }

    @Test func machineInformationUsesAPopupInsteadOfANavigationDestination() {
        #expect(!AppSection.allCases.map(\.rawValue).contains("Machines"))
    }

    @Test @MainActor func openingAConversationRoutesToItsChatOrBoardWorkspace() async {
        let store = DieterStore(liveEnvironment: false)
        var firstProject = Dieter_V1_Project()
        firstProject.id = "p_first"
        firstProject.name = "First"
        var targetProject = Dieter_V1_Project()
        targetProject.id = "p_target"
        targetProject.name = "Target"
        var firstBoard = Dieter_V1_Board()
        firstBoard.id = "b_first"
        firstBoard.projectID = firstProject.id
        var targetBoard = Dieter_V1_Board()
        targetBoard.id = "b_target"
        targetBoard.projectID = targetProject.id
        var boardCard = Dieter_V1_Card()
        boardCard.id = "c_board"
        boardCard.projectID = targetProject.id
        boardCard.boardID = targetBoard.id
        var chat = Dieter_V1_Card()
        chat.id = "c_chat"
        chat.projectID = targetProject.id
        chat.scope = "chat"

        store.projectDirectory = [firstProject.id: firstProject, targetProject.id: targetProject]
        store.navigationBoards = [firstProject.id: [firstBoard], targetProject.id: [targetBoard]]
        store.navigationCards = [targetProject.id: [boardCard]]
        store.chats = [chat]
        store.selectedProjectID = firstProject.id
        store.selectedBoardID = firstBoard.id
        store.section = .settings
        await store.openInbox()
        await store.openConversation(cardID: boardCard.id, fromInbox: true)
        #expect(store.section == .inbox)
        #expect(store.selectedCardID == boardCard.id)
        #expect(store.selectedProjectID == targetProject.id)
        #expect(store.selectedBoardID == targetBoard.id)
        await store.openInbox()
        #expect(store.selectedCardID == boardCard.id)

        await store.openConversation(cardID: chat.id, fromInbox: true)
        #expect(store.section == .inbox)
        #expect(store.selectedCardID == nil)
        #expect(store.selectedChatID == chat.id)
        await store.conversationContext.openConversation(cardID: chat.id, chat: true)
        #expect(store.section == .inbox)
        store.closeConversation()
        #expect(store.section == .inbox)
        #expect(store.selectedChatID == nil)

        await store.openConversation(cardID: boardCard.id)

        #expect(store.section == .board)
        #expect(store.selectedProjectID == targetProject.id)
        #expect(store.selectedBoardID == targetBoard.id)
        #expect(store.selectedCardID == boardCard.id)
        #expect(store.selectedChatID == nil)
        #expect(store.state.cards.map(\.id) == [boardCard.id])

        await store.openConversation(cardID: chat.id)

        #expect(store.section == .chats)
        #expect(store.selectedProjectID == targetProject.id)
        #expect(store.selectedCardID == nil)
        #expect(store.selectedChatID == chat.id)
    }
}
