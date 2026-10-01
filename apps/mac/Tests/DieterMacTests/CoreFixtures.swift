import DieterAPI
import Foundation
import SharedCore
@testable import DieterMac

extension AppSession {
    /// Folds `state` as the shared core's workspace slice, as a sync would
    /// deliver it. View and selection tests use this instead of a network.
    func foldFixture(_ state: Dieter_V1_State, retiredBoards: [Dieter_V1_Board] = [], daemonID: String = "fixture") {
        var projects = state.projects
        if state.hasProject, !state.project.id.isEmpty, !projects.contains(where: { $0.id == state.project.id }) {
            projects.append(state.project)
        }
        var slice = ClientWorkspaceSlice()
        slice.projects = projects
        slice.boards = state.boards
        slice.cards = state.cards + state.chats
        slice.retiredBoards = retiredBoards + state.archives.retiredBoards
        slice.loaded = true
        slice.projectReplicas = Dictionary(projects.map { ($0.id, daemonID) }, uniquingKeysWith: { first, _ in first })
        foldWorkspace(slice)
    }
}

extension ScriptedCoreClient {
    /// Publishes a full conversation slice for `cardID`, as the core would.
    func emitConversation(
        _ cardID: String, daemonID: String = "fixture", _ build: (inout ClientConversationSlice) -> Void = { _ in }
    ) {
        emit(.conversation, scope: cardID) { update in
            var slice = ClientConversationSlice()
            slice.cardID = cardID
            slice.daemonID = daemonID
            slice.card.id = cardID
            slice.conversation.cardID = cardID
            build(&slice)
            update.conversation = slice
        }
    }
}

/// A transcript message with one text part.
func fixtureMessage(_ id: String, role: String = "user", text: String? = nil) -> Dieter_V1_UiMessage {
    var message = Dieter_V1_UiMessage()
    message.id = id
    message.role = role
    var part = Dieter_V1_MessagePart()
    part.type = "text"
    part.text = text ?? id
    message.parts = [part]
    return message
}

extension ConversationModel {
    /// Resets paging to `snapshot`'s live window, as a fresh open would.
    func resetHistory(to snapshot: Dieter_V1_ConversationSnapshot) {
        resetConversationHistory()
        conversationHistoryStart = Int(snapshot.page.start)
        conversationHistoryTotal = Int(snapshot.page.total)
        conversationHistoryHasMore = snapshot.page.hasMore_p
    }
}
