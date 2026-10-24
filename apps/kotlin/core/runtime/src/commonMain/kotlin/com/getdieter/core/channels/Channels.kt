package com.getdieter.core.channels

import com.getdieter.api.v1.ChannelClaim
import com.getdieter.api.v1.ChannelFrame
import com.getdieter.api.v1.ChannelMessage
import com.getdieter.api.v1.ChannelSummary
import com.getdieter.api.v1.ListChannelsRequest
import com.getdieter.api.v1.MarkChannelReadRequest
import com.getdieter.api.v1.PinChannelMessageRequest
import com.getdieter.api.v1.PostChannelMessageRequest
import com.getdieter.api.v1.ReleaseChannelClaimsRequest
import com.getdieter.api.v1.WatchChannelRequest
import com.getdieter.client.v1.ChannelMachineSection
import com.getdieter.client.v1.ChannelPost
import com.getdieter.client.v1.ChannelRef
import com.getdieter.client.v1.ChannelStreamView
import com.getdieter.client.v1.ChannelsSlice
import com.getdieter.core.runtime.Backoff
import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.CoreLogger
import com.getdieter.core.runtime.Deadlines
import com.getdieter.core.runtime.FailureKind
import com.getdieter.core.runtime.Failures
import com.getdieter.core.session.MachineSessions
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlin.uuid.Uuid
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** A project's channel on the machine that hosts it. */
data class ChannelKey(val daemonId: String, val projectId: String)

/** One machine's channels as it last listed them. */
data class MachineChannels(
    val daemonId: String,
    val channels: List<ChannelSummary> = emptyList(),
    /** The last listing failed; [channels] are from before. */
    val error: String? = null,
)

data class ChannelsView(
    /** Machines with channels, in reachability order (this device's first). */
    val machines: List<MachineChannels> = emptyList(),
    /** Machines are being read for the first time. */
    val loading: Boolean = false,
    val loaded: Boolean = false,
    /** Some machine was reachable at the last listing. */
    val reachable: Boolean = false,
    val selected: ChannelKey? = null,
    val stream: ChannelStreamState = ChannelStreamState(),
    /** Why the stream is reconnecting. */
    val streamError: String? = null,
    /** Why the last command failed. */
    val actionError: String? = null,
    val sending: Boolean = false,
    /** The stream is on screen. */
    val active: Boolean = false,
) {
    fun summary(key: ChannelKey): ChannelSummary? =
        machines
            .firstOrNull { it.daemonId == key.daemonId }
            ?.channels
            ?.firstOrNull { it.project_id == key.projectId }

    /** Unread messages of channels that are on. */
    val unread: Int
        get() = machines.sumOf { machine ->
            machine.channels.filter { it.enabled }.sumOf { it.unread }
        }

    /**
     * The client contract's view: the list, the empty state and the selected channel's stream.
     * [name] names a machine; [reachable] says whether one is reachable now.
     */
    fun slice(
        switches: ChannelSwitches,
        name: (String) -> String,
        reachable: (String) -> Boolean,
        now: Instant,
    ): ChannelsSlice {
        val empty = machines.all { it.channels.isEmpty() }
        val (title, detail) =
            when {
                !empty -> "" to ""
                !switches.anyEnabled -> OFF_TITLE to OFF_DETAIL
                loading || !loaded -> "" to ""
                !this.reachable -> UNREACHABLE_TITLE to UNREACHABLE_DETAIL
                else -> NONE_TITLE to NONE_DETAIL
            }
        return ChannelsSlice(
            machines =
                machines
                    .filter { it.channels.isNotEmpty() || it.error != null }
                    .map { machine ->
                        ChannelMachineSection(
                            daemon_id = machine.daemonId,
                            name = name(machine.daemonId),
                            error = machine.error.orEmpty(),
                            channels =
                                machine.channels
                                    .sortedWith(
                                        compareBy(
                                            { it.project_name.lowercase() },
                                            { it.project_id },
                                        )
                                    )
                                    .map {
                                        ChannelRules.listRow(
                                            machine.daemonId,
                                            it,
                                            selected == ChannelKey(machine.daemonId, it.project_id),
                                        )
                                    },
                        )
                    },
            unread = unread,
            unread_label = ChannelRules.unreadLabel(unread),
            enabled = switches.anyEnabled,
            loading = loading && empty,
            empty_title = title,
            empty_detail = detail,
            stream = selected?.let { stream(it, name(it.daemonId), reachable(it.daemonId), now) },
        )
    }

    private fun stream(
        key: ChannelKey,
        machine: String,
        reachable: Boolean,
        now: Instant,
    ): ChannelStreamView {
        val summary = stream.summary ?: summary(key)
        val name = summary?.project_name?.ifBlank { null } ?: key.projectId
        val enabled = summary?.enabled ?: false
        val titles = stream.titles
        val rows = ChannelRules.rows(stream.messages, summary?.seen_seq ?: 0, titles)
        val unread = summary?.unread ?: 0
        val members = summary?.members.orEmpty()
        val pins = ChannelRules.pins(stream.messages, titles)
        return ChannelStreamView(
            channel = ChannelRef(key.daemonId, key.projectId),
            title = "#$name",
            subtitle = "Project channel on $machine",
            enabled = enabled,
            loading = !stream.loaded,
            error = streamError.orEmpty(),
            claims_summary = ChannelRules.claimsSummary(stream.claims),
            rows = rows.rows,
            first_unread_row_id = if (unread > 0) rows.firstUnreadId.orEmpty() else "",
            unread = unread,
            claims = ChannelRules.claims(stream.claims, titles, now),
            members = ChannelRules.members(members),
            pins = pins,
            composer = ChannelRules.composer(name, enabled, reachable, machine, members, sending),
            claims_tab = ChannelRules.tab("Claims", stream.claims.size),
            members_tab = ChannelRules.tab("Agents", members.size),
            pins_tab = ChannelRules.tab("Pins", pins.size),
            action_error = actionError.orEmpty(),
        )
    }

    companion object {
        const val OFF_TITLE = "Agent channels are off"
        const val OFF_DETAIL =
            "Turn them on in Settings › Experimental, or for one project or board in its settings. " +
                "Agents working in the same project can then message each other, claim the files " +
                "they change, and pin decisions."
        const val UNREACHABLE_TITLE = "No machine is reachable"
        const val UNREACHABLE_DETAIL =
            "Channels live on the machines that run your projects. They show here once one is " +
                "reachable."
        const val NONE_TITLE = "No channels yet"
        const val NONE_DETAIL =
            "A project's channel shows here once agent channels are on for it and a machine with " +
                "its checkout is reachable."
    }
}

/**
 * Agent channels across machines, for one view: every reachable machine lists its project channels
 * (on selection, after commands, and periodically while observed), and the selected channel streams
 * from the machine that hosts it, reconnecting after failures. Posts, pins, read positions, and
 * claim releases go to that machine. Nothing is read while every setting is off. Confined to the
 * core dispatcher.
 */
class Channels(
    private val sessions: MachineSessions,
    private val reachable: () -> List<String>,
    private val settings: StateFlow<ChannelSettingsView>,
    private val scope: CoroutineScope,
    private val logger: CoreLogger,
) {
    private val mutableView = MutableStateFlow(ChannelsView())
    val view: StateFlow<ChannelsView> = mutableView.asStateFlow()
    private val wake = Channel<Unit>(Channel.CONFLATED)
    private var generation = 0L
    private var watch: Job? = null
    private var watched: ChannelKey? = null

    /** The highest position this view marked read, by channel, until the machine reports it. */
    private val readFloors = mutableMapOf<ChannelKey, Long>()

    /** Shows nothing and stops reading; results in flight are dropped. */
    fun stop() {
        generation++
        stopWatch()
        readFloors.clear()
        mutableView.value = ChannelsView()
    }

    /**
     * Lists the channels while observed: at once, soon after a setting or the reachable machines
     * change or a command asks for it, and every [ACTIVE_REFRESH] while the stream shows (else
     * [IDLE_REFRESH], for the unread badge). Runs until cancelled.
     */
    suspend fun run(reachability: Flow<Collection<String>>): Unit = coroutineScope {
        launch {
            settings
                .map { it.switches }
                .distinctUntilChanged()
                .drop(1)
                .collect { wake.trySend(Unit) }
        }
        launch {
            reachability
                .map { it.toSet() }
                .distinctUntilChanged()
                .drop(1)
                .collect {
                    wake.trySend(Unit)
                }
        }
        while (true) {
            refresh()
            withTimeoutOrNull(if (view.value.active) ACTIVE_REFRESH else IDLE_REFRESH) {
                wake.receive()
            }
        }
    }

    /** Asks the run loop to list again soon. */
    fun requestRefresh() {
        wake.trySend(Unit)
    }

    /** Lists every reachable machine's channels now. */
    suspend fun refresh() {
        val bound = generation
        if (!settings.value.switches.anyEnabled) {
            show(null)
            mutableView.update {
                it.copy(machines = emptyList(), loading = false, loaded = true, reachable = true)
            }
            reconcileWatch()
            return
        }
        val machines = reachable()
        mutableView.update { if (it.loaded) it else it.copy(loading = true) }
        val results = coroutineScope { machines.map { id -> async { id to list(id) } }.awaitAll() }
        if (bound != generation) return
        mutableView.update { state ->
            val listed = results.mapNotNull { (id, result) ->
                when (result) {
                    is Listing.Listed -> MachineChannels(id, result.channels.map { floor(id, it) })
                    is Listing.Failed ->
                        (state.machines.firstOrNull { it.daemonId == id } ?: MachineChannels(id))
                            .copy(error = result.message)
                    Listing.Unsupported -> null
                }
            }
            // The selected channel's summary is as fresh as the listing's.
            val selected = state.selected
            val fresh = selected?.let { key ->
                listed
                    .firstOrNull { it.daemonId == key.daemonId }
                    ?.channels
                    ?.firstOrNull { it.project_id == key.projectId }
            }
            state.copy(
                machines = listed,
                loading = false,
                loaded = true,
                reachable = machines.isNotEmpty(),
                stream =
                    if (fresh != null && state.stream.loaded) state.stream.copy(summary = fresh)
                    else state.stream,
            )
        }
        // A shown list without a selection opens its first channel that is on.
        val state = view.value
        if (state.selected == null && state.active) {
            val first =
                state.machines.firstNotNullOfOrNull { machine ->
                    machine.channels
                        .filter { it.enabled }
                        .minWithOrNull(
                            compareBy({ it.project_name.lowercase() }, { it.project_id })
                        )
                        ?.let { ChannelKey(machine.daemonId, it.project_id) }
                }
            if (first != null) show(first)
        }
        reconcileWatch()
    }

    private sealed interface Listing {
        data class Listed(val channels: List<ChannelSummary>) : Listing

        data class Failed(val message: String) : Listing

        /** The machine runs a release without agent channels. */
        data object Unsupported : Listing
    }

    private suspend fun list(daemonId: String): Listing =
        try {
            val response =
                sessions.call(daemonId, Deadlines.CALL) {
                    it.ListChannels().execute(ListChannelsRequest())
                }
            Listing.Listed(response.channels)
        } catch (error: Throwable) {
            when {
                error is CancellationException -> throw error
                error is GrpcException && error.grpcStatus == GrpcStatus.UNIMPLEMENTED ->
                    Listing.Unsupported
                else -> Listing.Failed(Failures.message(error))
            }
        }

    /** [summary] with this view's read position, which the machine may not report yet. */
    private fun floor(daemonId: String, summary: ChannelSummary): ChannelSummary {
        val key = ChannelKey(daemonId, summary.project_id)
        val floor = readFloors[key] ?: return summary
        if (summary.seen_seq >= floor) {
            readFloors.remove(key)
            return summary
        }
        return summary.copy(
            seen_seq = floor,
            unread = if (summary.last_seq <= floor) 0 else summary.unread,
        )
    }

    /** Shows [key]'s channel, or none. */
    fun select(key: ChannelKey?) {
        show(key)
        reconcileWatch()
        requestRefresh()
    }

    private fun show(key: ChannelKey?) {
        if (key != view.value.selected) {
            mutableView.update {
                it.copy(
                    selected = key,
                    stream = ChannelStreamState(),
                    streamError = null,
                    actionError = null,
                    sending = false,
                )
            }
        }
    }

    /** The stream is on screen ([active]) or hidden. */
    fun setActive(active: Boolean) {
        if (active == view.value.active) return
        mutableView.update { it.copy(active = active) }
        reconcileWatch()
        if (active) requestRefresh()
    }

    private fun reconcileWatch() {
        val state = view.value
        val key = state.selected?.takeIf { state.active }
        if (key == null) {
            stopWatch()
            return
        }
        if (key == watched && watch?.isActive == true) return
        startWatch(key)
    }

    private fun stopWatch() {
        watch?.cancel()
        watch = null
        watched = null
    }

    private fun startWatch(key: ChannelKey) {
        watch?.cancel()
        watched = key
        val bound = generation
        fun current() = bound == generation && view.value.selected == key && view.value.active
        watch = scope.launch {
            var attempt = 0
            while (current()) {
                try {
                    coroutineScope {
                        sessions.call(key.daemonId) { client ->
                            val call = client.WatchChannel()
                            val frames =
                                call.executeIn(
                                    this,
                                    WatchChannelRequest(
                                        project_id = key.projectId,
                                        heartbeat_ms = HEARTBEAT_MS,
                                    ),
                                )
                            try {
                                for (frame in frames) {
                                    if (!current()) break
                                    receive(key, frame)
                                    attempt = 0
                                }
                            } finally {
                                call.cancel()
                            }
                        }
                    }
                } catch (error: Throwable) {
                    if (error is CancellationException) throw error
                    if (current())
                        mutableView.update { it.copy(streamError = Failures.message(error)) }
                }
                if (!current()) break
                delay(Backoff.STREAM.delay(attempt++))
            }
        }
    }

    /** One frame of [key]'s stream folded in; the list's summary follows the stream's. */
    internal fun receive(key: ChannelKey, frame: ChannelFrame) {
        if (view.value.selected != key) return
        mutableView.update { state ->
            var stream = state.stream.apply(frame)
            val summary = stream.summary?.let { floor(key.daemonId, it) }
            if (summary != null && summary != stream.summary)
                stream = stream.copy(summary = summary)
            state.copy(
                stream = stream,
                streamError = null,
                machines =
                    if (frame.summary == null) state.machines
                    else state.machines.withSummary(key, summary),
            )
        }
    }

    private fun List<MachineChannels>.withSummary(
        key: ChannelKey,
        summary: ChannelSummary?,
    ): List<MachineChannels> {
        summary ?: return this
        return map { machine ->
            if (machine.daemonId != key.daemonId) machine
            else
                machine.copy(
                    channels =
                        machine.channels.map { if (it.project_id == key.projectId) summary else it }
                )
        }
    }

    private fun selected(): ChannelKey =
        view.value.selected ?: throw CoreException(FailureKind.PERMANENT, "Choose a channel first.")

    /**
     * The selected channel's newest message is visible: the read position moves there. Shown at
     * once; a failure only shows the machine's position again at the next listing.
     */
    suspend fun markRead() {
        val state = view.value
        val key = state.selected ?: return
        val seq = state.stream.newestSeq
        val summary = state.stream.summary ?: state.summary(key) ?: return
        if (seq <= summary.seen_seq || seq <= (readFloors[key] ?: 0)) return
        readFloors[key] = seq
        mutableView.update { current ->
            if (current.selected != key) current
            else {
                val stream = current.stream.read(seq)
                current.copy(
                    stream = stream,
                    machines =
                        current.machines.withSummary(
                            key,
                            (stream.summary ?: current.summary(key))?.let {
                                floor(key.daemonId, it)
                            },
                        ),
                )
            }
        }
        try {
            sessions.call(key.daemonId, Deadlines.CALL) {
                it.MarkChannelRead().execute(MarkChannelReadRequest(key.projectId, seq))
            }
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            logger.info(
                "Channels",
                "marking ${key.projectId} read failed: ${Failures.message(error)}",
            )
            readFloors.remove(key)
            requestRefresh()
        }
    }

    /** Posts [post] to the selected channel as the user; a failure is thrown and shown. */
    suspend fun post(post: ChannelPost): ChannelMessage {
        val key = selected()
        ChannelRules.bodyProblem(post.body)?.let { throw CoreException(FailureKind.PERMANENT, it) }
        if (post.wake && post.to_card_ids.isEmpty())
            throw CoreException(FailureKind.PERMANENT, "Choose who to wake.")
        val request =
            PostChannelMessageRequest(
                project_id = key.projectId,
                to_card_ids = post.to_card_ids.distinct(),
                thread_id = post.thread_id,
                kind = ChannelRules.kindName(post.kind),
                body = post.body.trim(),
                wake = post.wake,
                operation_id = "app-${Uuid.random()}",
            )
        return command(key, sending = true) {
            val message =
                sessions.call(key.daemonId, Deadlines.CALL) {
                    it.PostChannelMessage().execute(request)
                }
            upsert(key, message)
            message
        }
    }

    suspend fun pin(messageId: String, pinned: Boolean) {
        val key = selected()
        command(key) {
            val message =
                sessions.call(key.daemonId, Deadlines.CALL) {
                    it.PinChannelMessage()
                        .execute(PinChannelMessageRequest(key.projectId, messageId, pinned))
                }
            upsert(key, message)
        }
    }

    /** Releases [cardId]'s claim on [path] (every claim of it when empty). */
    suspend fun release(cardId: String, path: String) {
        val key = selected()
        if (cardId.isBlank()) throw CoreException(FailureKind.PERMANENT, "Choose a claim.")
        command(key) {
            val released: List<ChannelClaim> =
                sessions
                    .call(key.daemonId, Deadlines.CALL) {
                        it.ReleaseChannelClaims()
                            .execute(
                                ReleaseChannelClaimsRequest(
                                    card_id = cardId,
                                    paths = listOfNotNull(path.ifBlank { null }),
                                )
                            )
                    }
                    .claims
            mutableView.update {
                if (it.selected == key) it.copy(stream = it.stream.without(released)) else it
            }
        }
    }

    private fun upsert(key: ChannelKey, message: ChannelMessage) {
        mutableView.update {
            if (it.selected == key) it.copy(stream = it.stream.upsert(message)) else it
        }
    }

    private suspend fun <T> command(
        key: ChannelKey,
        sending: Boolean = false,
        block: suspend () -> T,
    ): T {
        mutableView.update { it.copy(actionError = null, sending = it.sending || sending) }
        try {
            return block()
        } catch (error: Throwable) {
            if (error !is CancellationException && view.value.selected == key)
                mutableView.update { it.copy(actionError = Failures.message(error)) }
            throw error
        } finally {
            if (sending) mutableView.update { it.copy(sending = false) }
            requestRefresh()
        }
    }

    companion object {
        val ACTIVE_REFRESH = 10.seconds
        val IDLE_REFRESH = 60.seconds

        /** Heartbeats every 5 s, so a claim released without a waiter shows within seconds. */
        const val HEARTBEAT_MS = 5_000
    }
}
