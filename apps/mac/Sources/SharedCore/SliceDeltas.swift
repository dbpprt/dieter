import DieterAPI
import Foundation

// The keyed slices' deltas, folded onto the slice they follow exactly as the
// core computes them (`KeyedList`). A delta replaces every unkeyed field.

extension ClientWorkspaceSlice {
    /// This workspace after `delta`: projects and boards are complete, cards keyed.
    package func applying(_ delta: ClientWorkspaceDelta) -> ClientWorkspaceSlice {
        var slice = self
        slice.projects = delta.projects
        slice.boards = delta.boards
        slice.cards = KeyedList.apply(
            cards, upserted: delta.upsertedCards, removed: delta.removedCardIds,
            order: delta.orderChanged ? delta.cardOrder : nil, key: \.id)
        slice.pendingCardIds = delta.pendingCardIds
        slice.loaded = delta.loaded
        slice.projectReplicas = delta.projectReplicas
        slice.retiredBoards = delta.retiredBoards
        slice.settings = delta.settings
        slice.boardAttention = delta.boardAttention
        return slice
    }
}

extension ClientConversationSlice {
    /// This conversation after `delta`: messages and timeline rows are keyed.
    package func applying(_ delta: ClientConversationDelta) -> ClientConversationSlice {
        var value = self
        value.card = delta.card
        value.conversation = delta.conversation
        value.messages = KeyedList.apply(
            messages, upserted: delta.upsertedMessages, removed: delta.removedMessageIds,
            order: delta.orderChanged ? delta.messageOrder : nil, key: \.id)
        value.timeline = KeyedList.apply(
            timeline, upserted: delta.upsertedTimeline, removed: delta.removedTimelineIds,
            order: delta.timelineOrderChanged ? delta.timelineOrder : nil, key: \.id)
        value.unattachedPlanIds = delta.unattachedPlanIds
        value.loading = delta.loading
        value.syncing = delta.syncing
        value.error = delta.error
        value.pending = delta.pending
        value.hasEarlier_p = delta.hasEarlier_p
        value.loadingEarlier = delta.loadingEarlier
        value.browsingEarlier = delta.browsingEarlier
        value.retrying = delta.retrying
        value.refreshedAtMillis = delta.refreshedAtMillis
        if delta.hasTurnFailure { value.turnFailure = delta.turnFailure } else { value.clearTurnFailure() }
        value.project = delta.project
        value.board = delta.board
        value.page = delta.page
        if !delta.cardID.isEmpty { value.cardID = delta.cardID }
        value.daemonID = delta.daemonID
        value.earlierCount = delta.earlierCount
        value.state = delta.state
        return value
    }
}
