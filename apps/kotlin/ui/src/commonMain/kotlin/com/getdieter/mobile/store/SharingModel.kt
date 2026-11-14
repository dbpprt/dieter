package com.getdieter.mobile.store

import com.getdieter.api.v1.MessagePart
import com.getdieter.client.v1.WorkspaceSlice
import com.getdieter.core.composition.Attachments
import com.getdieter.mobile.navigation.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** Where another app's share goes: a new task, an existing task or chat, or a synced folder. */
enum class ShareDestination {
    NEW_TASK,
    TASK,
    CHAT,
    /** "Save to folder…": the files are saved into a synced folder on this device. */
    FOLDER,
}

/** A file another app shared, unread: [source] as the platform reads it and its [name]. */
class SharedFile(val source: String, val name: String)

/**
 * What another app shared into Dieter. [problem] reports items that could not be read; the rest
 * still arrive. A folder share carries its [files] unread, so large files never pass through
 * memory.
 */
class SharedItems(
    val text: String,
    val attachments: List<MessagePart>,
    val destination: ShareDestination,
    val problem: String = "",
    val files: List<SharedFile> = emptyList(),
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
    private val folders: FoldersModel,
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
        if (items.destination == ShareDestination.FOLDER) {
            target.value = items
            navigator.present(MobileRoute.SaveToFolder)
            return
        }
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

    /**
     * Saves the waiting share's files into [folderId] and closes the picker once they are saved.
     */
    fun saveInto(folderId: String) {
        val items = target.value ?: return
        folders.save(
            folderId,
            items.files.map { com.getdieter.client.v1.FolderSaveSource(it.source, it.name) },
        ) {
            if (target.value === items) target.value = null
            navigator.dismiss()
        }
    }

    fun cancel() {
        target.value = null
        navigator.dismiss()
    }

    /** Hands a conversation composer the items shared into it, once. */
    fun takeComposerShare(cardId: String): SharedItems? =
        composerShares.value[cardId]?.also { composerShares.value = composerShares.value - cardId }
}
