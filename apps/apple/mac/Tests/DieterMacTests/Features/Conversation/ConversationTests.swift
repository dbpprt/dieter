import DieterAPI
import Foundation
import Testing
@testable import DieterMacKit

/// Composer return and history navigation, the viewport and timeline presentation, and workspace choices.
struct ConversationTests {
    @Test func shiftReturnCreatesANewlineAndPlainReturnSends() {
        #expect(ComposerReturnPolicy.sendsMessage(shiftPressed: false))
        #expect(!ComposerReturnPolicy.sendsMessage(shiftPressed: true))
    }

    @Test func composerHistoryWalksBackwardAndReturnsToThePreservedDraft() {
        let entries = ["First prompt", "Second prompt", "Third prompt"]
        var navigation = ComposerHistoryNavigation()

        #expect(navigation.navigate(.older, entries: entries, currentText: "unfinished draft") == "Third prompt")
        #expect(navigation.navigate(.older, entries: entries, currentText: "Third prompt") == "Second prompt")
        #expect(navigation.navigate(.older, entries: entries, currentText: "Second prompt") == "First prompt")
        #expect(navigation.navigate(.older, entries: entries, currentText: "First prompt") == "First prompt")
        #expect(navigation.navigate(.newer, entries: entries, currentText: "First prompt") == "Second prompt")
        #expect(navigation.navigate(.newer, entries: entries, currentText: "Second prompt") == "Third prompt")
        #expect(navigation.navigate(.newer, entries: entries, currentText: "Third prompt") == "unfinished draft")
        #expect(!navigation.isBrowsing)
        #expect(navigation.navigate(.newer, entries: entries, currentText: "unfinished draft") == nil)
    }

    @Test func composerHistoryUsesDeliveredUserTextAndStopsWhenEditing() {
        func message(_ id: String, role: String, text: String) -> Dieter_V1_UiMessage {
            var part = Dieter_V1_MessagePart(); part.type = "text"; part.text = text
            var message = Dieter_V1_UiMessage(); message.id = id; message.role = role; message.parts = [part]
            return message
        }
        var queued = Dieter_V1_QueuedMessage(); queued.id = "queued"
        let entries = ComposerHistoryNavigation.entries(
            messages: [
                message("one", role: "user", text: "First"),
                message("assistant", role: "assistant", text: "Answer"),
                message("queued", role: "user", text: "Still queued"),
                message("two", role: "human", text: "Second"),
            ],
            queuedMessages: [queued]
        )
        #expect(entries == ["First", "Second"])

        var navigation = ComposerHistoryNavigation()
        #expect(navigation.navigate(.older, entries: entries, currentText: "") == "Second")
        navigation.observeTextChange("Second, edited")
        #expect(!navigation.isBrowsing)
    }

    @Test func composerHistoryOnlyTakesOverAtMultilineEdges() {
        let text = "first line\nsecond line"
        #expect(ComposerHistoryNavigation.isAtBoundary(.older, text: text, selection: NSRange(location: 3, length: 0)))
        #expect(
            !ComposerHistoryNavigation.isAtBoundary(.older, text: text, selection: NSRange(location: 14, length: 0)))
        #expect(!ComposerHistoryNavigation.isAtBoundary(.newer, text: text, selection: NSRange(location: 3, length: 0)))
        #expect(ComposerHistoryNavigation.isAtBoundary(.newer, text: text, selection: NSRange(location: 14, length: 0)))
    }

    @Test func conversationViewportTailsUntilTheUserDetaches() {
        let awaiting = ConversationViewportMode.awaitingInitial(conversationID: "chat-one")
        #expect(ConversationScrollBehavior.followsLatest(awaiting))
        #expect(!ConversationScrollBehavior.showsJumpToLatest(viewportMode: awaiting))
        #expect(!ConversationScrollBehavior.initialPositionComplete(awaiting))
        #expect(
            !ConversationScrollBehavior.initialPositionComplete(
                .awaitingInitial(conversationID: "a previous conversation")))

        let following = ConversationScrollBehavior.afterUserScroll(isAtLatest: true)
        #expect(following == .followingLatest)
        #expect(ConversationScrollBehavior.followsLatest(following))
        #expect(!ConversationScrollBehavior.showsJumpToLatest(viewportMode: following))
        #expect(ConversationScrollBehavior.initialPositionComplete(following))

        let detached = ConversationScrollBehavior.afterUserScroll(isAtLatest: false)
        #expect(detached == .detached)
        #expect(!ConversationScrollBehavior.followsLatest(detached))
        #expect(ConversationScrollBehavior.showsJumpToLatest(viewportMode: detached))

        #expect(ConversationScrollBehavior.isAtLatest(visibleMaxY: 1_000, contentHeight: 1_000))
        #expect(ConversationScrollBehavior.isAtLatest(visibleMaxY: 999, contentHeight: 1_000))
        #expect(!ConversationScrollBehavior.isAtLatest(visibleMaxY: 950, contentHeight: 1_000))
        #expect(
            ConversationScrollBehavior.isAtLatest(
                visibleMaxY: 1_828, contentHeight: 1_730, bottomInset: 98))
        #expect(
            !ConversationScrollBehavior.isAtLatest(
                visibleMaxY: 1_828, contentHeight: 1_730, bottomInset: 159))
        #expect(
            ConversationScrollBehavior.isAtLatest(
                visibleMaxY: 1_889, contentHeight: 1_730, bottomInset: 159))
        #expect(
            !ConversationScrollBehavior.isAtLatest(
                visibleMaxY: 1_000,
                contentHeight: 1_000,
                renderedThroughLatest: false
            )
        )
    }

    @Test func conversationTimelineStaysHiddenUntilItsInitialTailPositionLands() {
        let conversationID = "chat-one"
        #expect(
            ConversationTimelinePresentation.isReady(
                messageCount: 0,
                conversationID: conversationID,
                projectionConversationID: "",
                viewportMode: .awaitingInitial(conversationID: conversationID)))
        #expect(
            !ConversationTimelinePresentation.isReady(
                messageCount: 20,
                conversationID: conversationID,
                projectionConversationID: "chat-two",
                viewportMode: .followingLatest))
        #expect(
            !ConversationTimelinePresentation.isReady(
                messageCount: 20,
                conversationID: conversationID,
                projectionConversationID: conversationID,
                viewportMode: .awaitingInitial(conversationID: conversationID)))
        #expect(
            ConversationTimelinePresentation.isReady(
                messageCount: 20,
                conversationID: conversationID,
                projectionConversationID: conversationID,
                viewportMode: .followingLatest))
    }

    @Test func conversationProjectionIdentityIncludesTheSelectedConversation() {
        let chat = ConversationPresentationKey(
            conversationID: "chat-one",
            revision: 7,
            renderStart: 0,
            renderCount: 30
        )
        let card = ConversationPresentationKey(
            conversationID: "card-one",
            revision: 7,
            renderStart: 0,
            renderCount: 30
        )

        #expect(chat != card)
    }

    @Test func conversationWorkspacePickerUsesOnlySupportedCreationChoices() {
        #expect(ConversationWorkspaceMode.selectable("worktree") == .worktree)
        #expect(ConversationWorkspaceMode.selectable("WORKTREE") == .worktree)
        #expect(ConversationWorkspaceMode.selectable("project") == .project)
        #expect(ConversationWorkspaceMode.selectable("main") == .project)
        #expect(ConversationWorkspaceMode.selectable("branch") == .project)
        #expect(ConversationWorkspaceMode.selectable(nil) == .project)
        #expect(ConversationWorkspaceMode.allCases == [.worktree, .project])
        #expect(ConversationWorkspaceMode.worktree.title == "Worktree")
        #expect(ConversationWorkspaceMode.project.title == "Project directory")
    }
}
