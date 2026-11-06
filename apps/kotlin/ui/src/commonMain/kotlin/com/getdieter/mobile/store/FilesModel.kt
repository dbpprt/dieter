package com.getdieter.mobile.store

import com.getdieter.client.v1.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

data class MobileFileBuffer(val original: String, val text: String)

/** Files: the browsed folder and open document, and each document's unsaved edits. */
class FilesModel
internal constructor(
    private val context: StoreContext,
    private val workspace: StateFlow<WorkspaceSlice>,
    private val defaults: StateFlow<CreationSlice>,
    private val available: (daemonId: String) -> Boolean,
) {
    val slice = MutableStateFlow(FilesSlice())
    val buffers = MutableStateFlow<Map<String, MobileFileBuffer>>(emptyMap())

    internal fun subscribe() {
        context.observeAlways(Slice.SLICE_FILES, MobileStore.FILES_SCOPE) {
            it.files?.let { value ->
                slice.value =
                    if (value.document_unchanged) value.copy(document = slice.value.document)
                    else value
            }
        }
    }

    fun command(value: FilesCommand) =
        context.command(Command(files = value.copy(scope = MobileStore.FILES_SCOPE)))

    /**
     * Binds Files to [projectId]'s checkout [checkoutId], or the project's default checkout when
     * empty; see [toolCheckout].
     */
    fun bindProject(projectId: String, checkoutId: String = "") {
        val project = workspace.value.projects.firstOrNull { it.id == projectId } ?: return
        val checkout =
            project.toolCheckout(
                checkoutId,
                defaults.value.checkouts[project.id].orEmpty(),
                available,
            ) ?: return
        bind(
            FilesTarget(
                daemon_id = checkout.daemon_id,
                project_id = project.id,
                checkout_id = checkout.id,
                card_id = "",
            )
        )
    }

    /** Binds Files to [checkoutId] on [daemonId], e.g. for a workspace link in mail. */
    internal fun bindCheckout(daemonId: String, projectId: String, checkoutId: String) =
        bind(
            FilesTarget(
                daemon_id = daemonId,
                project_id = projectId,
                checkout_id = checkoutId,
                card_id = "",
            )
        )

    /** Binds Files to an open conversation's workspace. */
    internal fun bindCard(daemonId: String, projectId: String, cardId: String) =
        bind(
            FilesTarget(
                daemon_id = daemonId,
                project_id = projectId,
                checkout_id = "",
                card_id = cardId,
            )
        )

    private fun bind(target: FilesTarget) = context.action {
        context.core.dispatch(
            Command(files = FilesCommand(scope = MobileStore.FILES_SCOPE, bind = target))
        )
        context.core.dispatch(
            Command(files = FilesCommand(scope = MobileStore.FILES_SCOPE, load = FilesPath()))
        )
    }

    fun syncBuffer(key: String, content: String) {
        if (key.isEmpty()) return
        val previous = buffers.value[key]
        if (previous == null && buffers.value.size >= OPEN_BUFFERS) {
            val discard =
                buffers.value.entries.firstOrNull { it.value.original == it.value.text }?.key
            if (discard != null) discardBuffer(discard)
            else {
                context.error.value = "Save or discard an open file before editing another."
                return
            }
        }
        if (previous == null || previous.original == previous.text) savedBuffer(key, content)
    }

    fun editBuffer(key: String, original: String, text: String) {
        if (key.isEmpty()) return
        val previous = buffers.value[key]
        if (previous == null && buffers.value.size >= OPEN_BUFFERS) {
            context.error.value = "Save or discard an open file before editing another."
            return
        }
        buffers.value =
            (buffers.value + (key to MobileFileBuffer(previous?.original ?: original, text)))
    }

    fun savedBuffer(key: String, text: String) {
        buffers.value = buffers.value + (key to MobileFileBuffer(text, text))
    }

    fun discardBuffer(key: String) {
        buffers.value = buffers.value - key
    }

    private companion object {
        /** Open documents kept in memory, edited or not. */
        const val OPEN_BUFFERS = 32
    }
}
