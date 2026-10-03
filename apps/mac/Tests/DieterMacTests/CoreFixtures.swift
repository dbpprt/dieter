import DieterAPI
import DieterShared
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

extension AppSession {
    /// Shows `cards` on `board` as the core's board view lays them out. The
    /// board must be selected.
    func showBoardFixture(_ board: Dieter_V1_Board, cards: [Dieter_V1_Card]) {
        bindBoardView()
        boardViewModel.fold(
            ClientBoardViewSlice(
                rules: SharedRules.shared.boardView(
                    board: board.rulesData, cards: ClientCards.with { $0.cards = cards }.rulesData,
                    target: ClientBoardViewTarget.with { $0.boardID = board.id }.rulesData)))
        refreshBoardProjection()
    }
}

extension AppSession {
    /// Lists the session's chats in the chats pane as the core lays them
    /// out, every project's chats shown in full.
    func showChatsFixture() {
        var layout = navigation
        layout.chatsShowAll = Array(Set(chats.map(\.projectID))).sorted()
        chatsList.fold(
            ClientChatsSlice(
                rules: SharedRules.shared.chatList(
                    chats: ClientCards.with { $0.cards = chats }.rulesData,
                    projects: ClientProjects.with { $0.projects = projects }.rulesData,
                    navigation: layout.rulesData, query: "", archived: false)))
    }
}

extension ScriptedCoreClient {
    /// Publishes a full conversation slice for `cardID`, as the core would;
    /// a slice without rows gets one row per message, as the fixture builder lays them out.
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
            if slice.timeline.isEmpty {
                let queued = Set(slice.conversation.queue.map(\.id))
                slice.timeline = ConversationTimelineFixture.rows(slice.messages, queued: queued)
            }
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
        conversationHistoryTotal = Int(snapshot.page.total)
        conversationHistoryHasMore = snapshot.page.hasMore_p
    }
}

extension ClientScreenSlice {
    /// A screen slice in `phase` as the core reports it, for views and models under test.
    static func phase(_ phase: String, active: Bool = true) -> ClientScreenSlice {
        .with {
            $0.phase = phase
            $0.active = active
            $0.streaming = phase == "streaming"
            $0.failed = phase == "failed"
        }
    }
}
