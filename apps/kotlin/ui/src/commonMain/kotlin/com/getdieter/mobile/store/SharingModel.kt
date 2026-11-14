package com.getdieter.mobile.store

import com.getdieter.api.v1.MessagePart
import com.getdieter.client.v1.WorkspaceSlice
import com.getdieter.core.composition.Attachments
import com.getdieter.mobile.navigation.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** Where another app's share goes: a new task, or an existing task or chat. */
enum class ShareDestination {
    NEW_TASK,
    TASK,
    CHAT,
}

/**
 * What another app shared into Dieter. [problem] reports items that could not be read; the rest
 * still arrive.
 */
class SharedItems(
    val text: String,
    val attachments: List<MessagePart>,
    val destination: ShareDestination,
    val problem: String = "",
)

/** Route changes a holder asks the coordinator for; the coordinator binds their scopes. */
internal interface StoreNavigator {
    fun present(route: MobileRoute)

    fun dismiss()

    fun openConversation(cardId: String)

    fun newConversation(chat: Boolean)
}

/** Shares from other apps: the one waiting for the workspace or a target, and composer items. */
class SharingModel
internal constructor(
    private val context: StoreContext,
    private val workspace: StateFlow<WorkspaceSlice>,
    private val creation: CreationModel,
    private val navigator: StoreNavigator,
) {
    /** A share waiting for the person to choose its task or chat. */
    val target = MutableStateFlow<SharedItems?>(null)
    /** Shared items each conversation's composer takes when it opens. */
    val composerShares = MutableStateFlow<Map<String, SharedItems>>(emptyMap())
    private var pending: SharedItems? = null

    /** Receives another app's share; it opens once the workspace has loaded. */
    fun receive(items: SharedItems) {
        pending = items
        deliver()
    }

    internal fun deliver() {
        if (!workspace.value.loaded) return
        val items = pending ?: return
        pending = null
        if (items.problem.isNotEmpty()) context.error.value = items.problem
        val attachments =
            Attachments.appending(emptyList(), items.attachments).getOrElse {
                context.error.value = it.message.orEmpty()
                emptyList()
            }
        if (items.destination == ShareDestination.NEW_TASK) {
            navigator.newConversation(chat = false)
            creation.update(
                creation.intent.value.copy(prompt = items.text, attachments = attachments)
            )
            return
        }
        target.value = SharedItems(items.text, attachments, items.destination)
        navigator.present(MobileRoute.ShareTarget(items.destination == ShareDestination.CHAT))
    }

    /** Sends the waiting share to [cardId]'s composer and opens that conversation. */
    fun shareInto(cardId: String) {
        val items = target.value ?: return
        target.value = null
        composerShares.value = composerShares.value + (cardId to items)
        navigator.dismiss()
        navigator.openConversation(cardId)
    }

    fun cancel() {
        target.value = null
        navigator.dismiss()
    }

    /** Hands a conversation composer the items shared into it, once. */
    fun takeComposerShare(cardId: String): SharedItems? =
        composerShares.value[cardId]?.also { composerShares.value = composerShares.value - cardId }
}
