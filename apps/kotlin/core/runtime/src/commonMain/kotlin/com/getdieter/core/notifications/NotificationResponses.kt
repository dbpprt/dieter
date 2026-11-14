package com.getdieter.core.notifications

import com.getdieter.api.v1.Card
import com.getdieter.api.v1.MailFolder
import com.getdieter.client.v1.MailMessageRef
import com.getdieter.core.navigation.OpenTarget

/** What a tap on, or an action of, a notification the core posted does. */
sealed interface NotificationRoute {
    /** Changes the message in place (Mark as Read, Archive); nothing opens. */
    data class ChangeMail(
        val ref: MailMessageRef,
        val read: Boolean? = null,
        val folder: MailFolder = MailFolder.MAIL_FOLDER_UNSPECIFIED,
    ) : NotificationRoute

    /** Opens Mail with the message selected. */
    data class OpenMail(val ref: MailMessageRef) : NotificationRoute

    /** Moves the card to its board's done lane; nothing opens. */
    data class FinishCard(val cardId: String) : NotificationRoute

    /** Opens the conversation where it belongs. */
    data class OpenConversation(val cardId: String) : NotificationRoute

    /** The conversation is gone: the Inbox shows what remains. */
    data object Inbox : NotificationRoute

    /** Nothing to do, e.g. an unknown notification or action. */
    data object None : NotificationRoute
}

object NotificationResponses {
    /**
     * Where the response to the notification [key] leads; an empty [action] is a tap. A mail
     * notification's Mark as Read and Archive change the message in place, and a tap or Open opens
     * it. A conversation's (a result, a review, a running chat) opens as [open] resolves its card
     * ([com.getdieter.core.navigation.OpenRequests.resolve]); one that may still arrive opens by
     * ID. Mark done finishes a card ready for review when [canFinish] it, else it opens the card.
     */
    fun route(
        key: String,
        action: String,
        open: (cardId: String) -> OpenTarget,
        canFinish: (Card) -> Boolean,
    ): NotificationRoute {
        val chosen = action.trim().uppercase()
        NotificationContent.mailRef(key)?.let { ref ->
            return when (chosen) {
                NotificationAction.MARK_READ.name -> NotificationRoute.ChangeMail(ref, read = true)
                NotificationAction.ARCHIVE.name ->
                    NotificationRoute.ChangeMail(ref, folder = MailFolder.MAIL_FOLDER_ARCHIVE)
                TAP,
                NotificationAction.OPEN.name -> NotificationRoute.OpenMail(ref)
                else -> NotificationRoute.None
            }
        }
        val prefix =
            CONVERSATION_PREFIXES.firstOrNull(key::startsWith) ?: return NotificationRoute.None
        val cardId = key.removePrefix(prefix)
        if (cardId.isBlank() || chosen !in OPENING) return NotificationRoute.None
        return when (val target = open(cardId)) {
            is OpenTarget.Conversation ->
                if (
                    chosen == NotificationAction.MARK_DONE.name &&
                        prefix == REVIEW_PREFIX &&
                        canFinish(target.card)
                )
                    NotificationRoute.FinishCard(target.card.id)
                else NotificationRoute.OpenConversation(target.card.id)
            OpenTarget.Wait -> NotificationRoute.OpenConversation(cardId)
            OpenTarget.Inbox -> NotificationRoute.Inbox
        }
    }

    private const val TAP = ""
    private const val REVIEW_PREFIX = "review:"
    private val CONVERSATION_PREFIXES = listOf("result:", REVIEW_PREFIX, "running:")

    /** A tap, Open, or Mark done (which opens the card when it cannot finish it). */
    private val OPENING =
        setOf(TAP, NotificationAction.OPEN.name, NotificationAction.MARK_DONE.name)
}
