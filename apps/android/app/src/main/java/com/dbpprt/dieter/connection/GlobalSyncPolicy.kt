package com.dbpprt.dieter.connection

import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.Board
import com.dbpprt.dieter.v1.Project
import com.dbpprt.dieter.v1.GlobalDelta
import com.dbpprt.dieter.v1.GlobalSnapshot

internal const val SYNC_PROJECTION_PERSIST_INTERVAL_MS = 15_000L

internal fun GlobalDelta.changesWorkspace(): Boolean =
    projectsCount > 0 || removedProjectIdsCount > 0 ||
        boardsCount > 0 || removedBoardIdsCount > 0 ||
        cardsCount > 0 || removedCardIdsCount > 0 ||
        chatsCount > 0 || removedChatIdsCount > 0 ||
        hasSettings() || hasArchives()

internal fun GlobalDelta.changesProjection(): Boolean =
    changesWorkspace() || conversationsCount > 0 || removedConversationIdsCount > 0

/** Transcript-only sync preserves the workspace objects observed by navigation. */
internal fun DieterConnectionState.applyingConversationSync(
    snapshot: GlobalSnapshot,
    refreshedIds: Set<String>,
    refreshedAtMillis: Long?,
    limit: Int,
): DieterConnectionState {
    val synced = snapshot.conversationsList.mapTo(hashSetOf()) { it.detail.card.id }
    val conversations = LinkedHashMap(activeConversations)
    snapshot.conversationsList.forEach { incoming ->
        val id = incoming.detail.card.id
        conversations[id] = freshestConversation(conversations[id], incoming)
    }
    val iterator = conversations.keys.iterator()
    while (conversations.size > limit && iterator.hasNext()) {
        if (iterator.next() !in synced) iterator.remove()
    }
    val refreshes = conversationRefreshedAtMillis.toMutableMap()
    if (refreshedAtMillis != null) refreshedIds.forEach { refreshes[it] = refreshedAtMillis }
    refreshes.keys.retainAll(conversations.keys)
    return copy(
        activeConversations = conversations,
        liveSyncedConversationIds = synced,
        conversationRefreshedAtMillis = refreshes,
    )
}

internal fun syncProjectionShouldPersist(lastPersistedAtMillis: Long?, nowMillis: Long): Boolean =
    lastPersistedAtMillis == null || nowMillis - lastPersistedAtMillis >= SYNC_PROJECTION_PERSIST_INTERVAL_MS

internal fun applyGlobalDelta(snapshot: GlobalSnapshot, delta: GlobalDelta): GlobalSnapshot {
    fun <T> merge(current: List<T>, changed: List<T>, removed: Set<String>, id: (T) -> String): List<T> {
        if (changed.isEmpty() && removed.isEmpty()) return current
        val changedByID = changed.associateBy(id)
        return (current.filter { id(it) !in removed && id(it) !in changedByID } + changed)
    }
    val state = if (!delta.changesWorkspace()) snapshot.state else snapshot.state.toBuilder()
        .clearProjects()
        .addAllProjects(merge(snapshot.state.projectsList, delta.projectsList, delta.removedProjectIdsList.toSet(), Project::getId))
        .clearBoards()
        .addAllBoards(merge(snapshot.state.boardsList, delta.boardsList, delta.removedBoardIdsList.toSet(), Board::getId))
        .clearCards()
        .addAllCards(merge(snapshot.state.cardsList, delta.cardsList, delta.removedCardIdsList.toSet(), Card::getId))
        .clearChats()
        .addAllChats(merge(snapshot.state.chatsList, delta.chatsList, delta.removedChatIdsList.toSet(), Card::getId))
        .also { if (delta.hasArchives()) it.archives = delta.archives }
        .build()
    return snapshot.toBuilder()
        .setState(state)
        .clearConversations()
        .addAllConversations(
            merge(snapshot.conversationsList, delta.conversationsList, delta.removedConversationIdsList.toSet()) { it.detail.card.id },
        )
        .also { if (delta.hasSettings()) it.settings = delta.settings }
        .build()
}
