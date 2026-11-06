package com.getdieter.core.mail

import com.getdieter.api.v1.MailFolder
import com.getdieter.api.v1.MailRef
import com.getdieter.client.v1.MailBox
import com.getdieter.client.v1.MailFilter
import com.getdieter.client.v1.MailMessageRef
import com.getdieter.client.v1.MailPreferences
import com.getdieter.core.outbox.Outbox
import com.getdieter.core.platform.DeviceSettings
import com.getdieter.core.runtime.CoreLogger
import com.getdieter.core.runtime.Deadlines
import com.getdieter.core.runtime.Failures
import com.getdieter.core.session.MachineSessions
import com.getdieter.core.storage.CoreStorage
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * The account's mailbox on this device: the bodies it keeps and loads, its mail changes (journaled
 * in the [outbox] and shown at once), and this device's mail preferences. [projection] is the
 * mailbox as the machines' streams and the pending changes show it now. Confined to the core
 * dispatcher.
 */
class Mailbox(
    private val sessions: MachineSessions,
    private val outbox: Outbox,
    private val settings: DeviceSettings,
    private val scope: CoroutineScope,
    private val logger: CoreLogger,
    private val projection: () -> MailProjection,
) {
    private data class BodyKey(val machineId: String, val id: String, val digest: String)

    private var bodies: MailBodies? = null
    private var generation = 0L

    /** Bodies being read, or why the last read failed. */
    private val loads = HashMap<BodyKey, String?>()
    private var prefetching: Job? = null

    /** A pass was asked for while one ran, for these machines (null: every one). */
    private var again = false
    private var againMachines: Set<String>? = null
    private val surfaces = LinkedHashSet<MailSurface>()

    private val mutableRevision = MutableStateFlow(0L)

    /** Changes whenever a body arrives, starts loading, or fails. */
    val revision: StateFlow<Long> = mutableRevision.asStateFlow()

    private val mutablePreferences = MutableStateFlow(MailSettings.load(settings))
    val preferences: StateFlow<MailPreferences> = mutablePreferences.asStateFlow()

    /** Switches to [storage]'s bodies (one gateway's), e.g. when the active gateway changes. */
    fun bind(storage: CoreStorage?) {
        generation++
        prefetching?.cancel()
        prefetching = null
        again = false
        againMachines = null
        loads.clear()
        bodies = storage?.let { MailBodies(it, logger) }
        bump()
    }

    fun setPreferences(preferences: MailPreferences) {
        MailSettings.save(settings, preferences)
        mutablePreferences.value = MailSettings.load(settings)
    }

    // --- Views -------------------------------------------------------------------------

    internal fun attach(surface: MailSurface) {
        surfaces += surface
    }

    internal fun detach(surface: MailSurface) {
        surfaces -= surface
    }

    /** Messages an active view shows in its reading pane; they are not notified. */
    fun openRefs(): Set<MailMessageRef> =
        surfaces.mapNotNullTo(HashSet()) { it.view.value.takeIf { it.active }?.selected }

    private val active: Boolean
        get() = surfaces.any { it.view.value.active }

    // --- Bodies ------------------------------------------------------------------------

    /**
     * [item]'s body as the reading pane shows it: kept on this device, being read, or why it cannot
     * be read. A body neither kept nor failed is read from its reachable machine.
     */
    fun body(item: MailItem, machine: MailMachine): MailBody {
        val header = item.header
        bodies?.get(item.machineId, header.id, header.body_digest)?.let {
            return MailBody.Ready(it)
        }
        val key = BodyKey(item.machineId, header.id, header.body_digest)
        if (key in loads) return loads[key]?.let(MailBody::Unavailable) ?: MailBody.Loading
        if (!machine.reachable)
            return MailBody.Unavailable(machine.stale ?: "${machine.name} is offline")
        load(item)
        return MailBody.Loading
    }

    /** Reads [item]'s body again after a failure, e.g. when it is selected again. */
    internal fun retry(item: MailItem) {
        val key = BodyKey(item.machineId, item.header.id, item.header.body_digest)
        if (loads[key] != null) {
            loads.remove(key)
            bump()
        }
    }

    private fun load(item: MailItem): Job? {
        val header = item.header
        val key = BodyKey(item.machineId, header.id, header.body_digest)
        val target = bodies ?: return null
        if (key in loads || target.contains(key.machineId, key.id, key.digest)) return null
        loads[key] = null
        // Only a reading pane shows a body; one read ahead changes no view.
        val shown = { surfaces.any { it.view.value.selected == item.ref } }
        if (shown()) bump()
        val bound = generation
        return scope.launch {
            val failure =
                try {
                    val mail =
                        sessions.call(key.machineId, Deadlines.CALL) {
                            it.GetMail().execute(MailRef(key.id))
                        }
                    if (bound != generation) return@launch
                    val digest = mail.header_?.body_digest?.ifEmpty { null } ?: key.digest
                    target.put(key.machineId, key.id, digest, mail.body)
                    // A body that changed since the header synced shows once its header does.
                    if (digest == key.digest) null else "The message changed; it opens once synced."
                } catch (cancelled: CancellationException) {
                    if (bound == generation) loads.remove(key)
                    throw cancelled
                } catch (error: Throwable) {
                    Failures.message(error)
                }
            if (bound != generation) return@launch
            if (failure == null) loads.remove(key) else loads[key] = failure
            if (shown()) bump()
        }
    }

    /**
     * Reads unread bodies ahead, newest first, at most [PREFETCH_BYTES] per pass, from reachable
     * [machines] (every one when null), so they open without a connection later.
     */
    fun prefetch(machines: Set<String>? = null) {
        if (prefetching?.isActive == true) {
            val queued = againMachines
            againMachines =
                when {
                    !again -> machines
                    machines == null || queued == null -> null
                    else -> queued + machines
                }
            again = true
            return
        }
        val bound = generation
        prefetching = scope.launch {
            var targets = machines
            while (true) {
                pass(targets)
                if (bound != generation || !again) break
                targets = againMachines
                again = false
                againMachines = null
            }
        }
    }

    private suspend fun pass(machines: Set<String>?) {
        val mailbox = projection()
        val target = bodies ?: return
        var budget = PREFETCH_BYTES
        val candidates =
            mailbox.items
                .filter { item ->
                    val header = item.header
                    (machines == null || item.machineId in machines) &&
                        !header.read &&
                        MailRules.folder(header) != MailFolder.MAIL_FOLDER_TRASH &&
                        mailbox.machine(item.machineId).reachable &&
                        BodyKey(item.machineId, header.id, header.body_digest) !in loads &&
                        !target.contains(item.machineId, header.id, header.body_digest)
                }
                .sortedWith(MailRules.ORDER)
        for (item in candidates) {
            val size = item.header.body_bytes.toLong()
            if (size > budget) continue
            budget -= size
            load(item)?.join()
        }
    }

    /**
     * Fetches ahead while a mailbox is on screen, and once for each machine that becomes current;
     * reads failed for want of a connection are retried when machines become reachable. Runs until
     * cancelled.
     */
    suspend fun run(current: Flow<Set<String>>, reachable: Flow<Collection<String>>): Unit =
        coroutineScope {
            launch {
                reachable
                    .distinctUntilChanged { a, b -> a.toSet() == b.toSet() }
                    .drop(1)
                    .collect {
                        if (loads.values.any { it != null }) {
                            loads.entries.removeAll { it.value != null }
                            bump()
                        }
                        if (active) prefetch()
                    }
            }
            var before = emptySet<String>()
            current.collect { now ->
                val became = now - before
                before = now
                if (became.isNotEmpty()) prefetch(became)
            }
        }

    /** The mailbox changed: a view on screen fetches new unread bodies ahead. */
    fun mailChanged() {
        if (active) prefetch()
    }

    // --- Changes -----------------------------------------------------------------------

    /** Queues read, flag or folder changes of [refs] on their machines. */
    fun change(
        refs: Collection<MailMessageRef>,
        read: Boolean? = null,
        flagged: Boolean? = null,
        folder: MailFolder = MailFolder.MAIL_FOLDER_UNSPECIFIED,
    ) {
        for ((machine, ids) in refs.groupBy({ it.daemon_id }, { it.id })) {
            outbox.changeMail(machine, ids, read, flagged, folder)
        }
    }

    /** Queues deleting [refs] for good on their machines. */
    fun delete(refs: Collection<MailMessageRef>) {
        for ((machine, ids) in refs.groupBy({ it.daemon_id }, { it.id })) {
            outbox.deleteMail(machine, ids)
        }
    }

    /** Deletes every message in the Trash; an offline machine's wait in the outbox. */
    fun emptyTrash() {
        delete(
            projection()
                .items
                .filter { MailRules.inBox(it.header, MailBox.MAIL_BOX_TRASH) }
                .map { it.ref }
        )
    }

    private fun bump() {
        mutableRevision.update { it + 1 }
    }

    companion object {
        /** How much one pass reads ahead. */
        const val PREFETCH_BYTES = 8L * 1024 * 1024
    }
}

/**
 * One view's mailbox: the box it shows, its search and filter, and the message in its reading pane.
 * Selecting an unread message marks it read at once. Confined to the core dispatcher.
 */
class MailSurface(private val mailbox: Mailbox, private val projection: () -> MailProjection) {
    private val mutableView = MutableStateFlow(MailView())
    val view: StateFlow<MailView> = mutableView.asStateFlow()

    init {
        mailbox.attach(this)
    }

    /** The view closed. */
    fun stop() {
        mailbox.detach(this)
    }

    /** The account changed: nothing of the previous one stays selected. */
    fun reset() {
        mutableView.update { MailView(box = it.box, active = it.active) }
    }

    fun selectBox(box: MailBox) {
        mutableView.update {
            if (it.box == box) it.copy(actionError = null)
            else it.copy(box = box, selected = null, actionError = null)
        }
    }

    /** Shows [ref] in the reading pane, marking it read; null or an empty ref shows none. */
    fun select(ref: MailMessageRef?) {
        val chosen = ref?.takeIf { it.id.isNotBlank() && it.daemon_id.isNotBlank() }
        mutableView.update { it.copy(selected = chosen, actionError = null) }
        val item = chosen?.let { projection().item(it) } ?: return
        mailbox.retry(item)
        if (!item.header.read) command { mailbox.change(listOf(chosen), read = true) }
    }

    fun search(text: String) {
        mutableView.update { it.copy(search = text) }
    }

    fun filter(filter: MailFilter) {
        mutableView.update { it.copy(filter = filter) }
    }

    fun setActive(active: Boolean) {
        if (active == view.value.active) return
        mutableView.update { it.copy(active = active) }
        if (active) mailbox.prefetch()
    }

    fun change(
        refs: Collection<MailMessageRef>,
        read: Boolean?,
        flagged: Boolean?,
        folder: MailFolder,
    ) = command { mailbox.change(refs, read, flagged, folder) }

    fun delete(refs: Collection<MailMessageRef>) = command { mailbox.delete(refs) }

    fun emptyTrash() = command { mailbox.emptyTrash() }

    /** Marks every unread message the view lists read. */
    fun markAllRead(listed: Collection<MailMessageRef>) = command {
        mailbox.change(listed, read = true)
    }

    private fun command(block: () -> Unit) {
        mutableView.update { it.copy(actionError = null) }
        try {
            block()
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            mutableView.update { it.copy(actionError = Failures.message(error)) }
            throw error
        }
    }
}
