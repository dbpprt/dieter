package com.dbpprt.dieter.connection

import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.ConversationSnapshot

sealed interface DieterNotificationEvent {
    val card: Card

    data class ChatFinished(
        override val card: Card,
        val subagentCount: Int,
        val completedSubagentCount: Int,
        val resultPreview: String = "",
    ) : DieterNotificationEvent

    data class ReadyForReview(override val card: Card) : DieterNotificationEvent
}

/** The closing words of the final assistant turn, used as the notification result preview. */
internal fun conversationResultPreview(snapshot: ConversationSnapshot?, maxLength: Int = 320): String {
    val message = snapshot?.conversation?.messagesList.orEmpty().lastOrNull { candidate ->
        candidate.role.equals("assistant", true) || candidate.role.equals("agent", true)
    } ?: return ""
    val text = message.partsList
        .filter { it.type == "text" && it.text.isNotBlank() }
        .joinToString("\n") { it.text }
        .trim()
    if (text.length <= maxLength) return text
    return "…" + text.takeLast(maxLength - 1).substringAfter(' ').trim()
}

/** Emits only state transitions, never stale terminal notifications on startup. */
class NotificationTransitionTracker {
    private var initialized = false
    private var previousCards: Map<String, Card> = emptyMap()
    private var previousConversations: Map<String, ConversationSnapshot> = emptyMap()

    fun update(
        cards: List<Card>,
        chats: List<Card>,
        conversations: Map<String, ConversationSnapshot>,
        notificationBoardIds: Set<String> = emptySet(),
    ): List<DieterNotificationEvent> {
        val current = (cards + chats).associateBy(Card::getId)
        val events = if (!initialized) {
            emptyList()
        } else {
            buildList {
                chats.forEach { chat ->
                    val previous = previousCards[chat.id] ?: return@forEach
                    if (isActiveRuntime(previous.runtime) && !isActiveRuntime(chat.runtime)) {
                        val snapshot = conversations[chat.id] ?: previousConversations[chat.id]
                        val subagents = (previousConversations[chat.id] ?: conversations[chat.id])
                            ?.conversation?.subagentsList.orEmpty()
                        add(
                            DieterNotificationEvent.ChatFinished(
                                card = chat,
                                subagentCount = subagents.size,
                                completedSubagentCount = subagents.count { it.status in TERMINAL_SUBAGENT_STATES },
                                resultPreview = conversationResultPreview(snapshot),
                            ),
                        )
                    }
                }
                cards.forEach { card ->
                    val previous = previousCards[card.id] ?: return@forEach
                    if (
                        card.boardId in notificationBoardIds &&
                        !previous.lane.equals("review", true) &&
                        card.lane.equals("review", true)
                    ) {
                        add(DieterNotificationEvent.ReadyForReview(card))
                    }
                }
            }
        }
        initialized = true
        previousCards = current
        previousConversations = conversations
        return events
    }

    companion object {
        private val TERMINAL_SUBAGENT_STATES = setOf("completed", "failed", "aborted", "cancelled")
    }
}
