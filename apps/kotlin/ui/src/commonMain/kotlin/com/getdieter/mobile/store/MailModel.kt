package com.getdieter.mobile.store

import com.getdieter.api.v1.MailFolder
import com.getdieter.client.v1.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/**
 * Agent mail as the core presents it: the account-wide mailbox with its boxes, date groups and
 * unread badge, and the message in the reading pane. The core words, sorts, counts and loads
 * everything; this holder folds its slice and sends its commands. It lives as long as the store, so
 * the badge is live on every tab.
 */
class MailModel internal constructor(private val context: StoreContext) {
    val slice = MutableStateFlow(MailSlice())
    private var shown: MailMessageRef? = null
    private var active = false

    internal fun subscribe() {
        context.observeAlways(Slice.SLICE_MAIL, MobileStore.MAIL_SCOPE) {
            it.mail?.let { value -> slice.value = value }
        }
    }

    /** [ref] is in the reading pane, which marks it read and loads it; null shows none. */
    internal fun show(ref: MailMessageRef?) {
        if (ref == shown) return
        val previous = shown
        shown = ref
        if (ref != null || previous != null) send(MailCommand(select = ref ?: MailMessageRef()))
    }

    /** The mailbox is on screen: the core fetches unread bodies ahead. */
    internal fun setActive(on: Boolean) {
        if (on == active) return
        active = on
        send(MailCommand(active = Toggle(on)))
    }

    fun selectBox(box: MailBox) = send(MailCommand(select_box = box))

    fun search(text: String) = send(MailCommand(search = text), quiet = true)

    fun filter(filter: MailFilter) = send(MailCommand(filter = filter))

    /** Read, flag or folder changes; unset values stay as they are. */
    fun change(
        refs: List<MailMessageRef>,
        read: Boolean? = null,
        flagged: Boolean? = null,
        folder: MailFolder = MailFolder.MAIL_FOLDER_UNSPECIFIED,
    ) {
        if (refs.isEmpty()) return
        send(
            MailCommand(
                change = MailChange(refs = refs, read = read, flagged = flagged, folder = folder)
            )
        )
    }

    /** Deletes [refs] for good. */
    fun delete(refs: List<MailMessageRef>) {
        if (refs.isNotEmpty()) send(MailCommand(delete = MailRefs(refs = refs)))
    }

    fun emptyTrash() = send(MailCommand(empty_trash = Step()))

    fun markAllRead() = send(MailCommand(mark_all_read = Step()))

    /**
     * Sends [command] for the mail scope and folds the slice it returns. A [quiet] failure shows
     * only where the slice says why (its action error).
     */
    private fun send(command: MailCommand, quiet: Boolean = false) {
        if (context.closed) return
        context.scope.launch {
            try {
                val result = context.serialized {
                    context.core.dispatch(
                        Command(mail = command.copy(scope = MobileStore.MAIL_SCOPE))
                    )
                }
                result.mail?.let { slice.value = it }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Throwable) {
                if (!quiet) context.error.value = failure.message ?: "The mail command failed."
            }
        }
    }
}
