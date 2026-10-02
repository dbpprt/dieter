package com.dbpprt.dieter.core.sync

import com.dbpprt.dieter.api.v1.GlobalSnapshot
import com.dbpprt.dieter.api.v1.SharedArchives
import com.dbpprt.dieter.api.v1.State
import com.dbpprt.dieter.api.v1.SyncFrame
import com.dbpprt.dieter.api.v1.SyncRequest
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.CoreLogger
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.session.MachineSessions
import com.dbpprt.dieter.core.storage.CoreStorage
import com.dbpprt.dieter.core.store.WorkspaceStore
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

data class FeedConfig(
    val heartbeat: Duration = 5.seconds,
    /** Silence that declares the stream dead; the daemon heartbeats even while it builds its projection. */
    val staleAfter: Duration = 15.seconds,
    /** Messages per conversation carried in the feed's conversation tail. */
    val conversationLimit: Int = 30,
    /** Recently active conversations carried in the tail. */
    val recentConversationLimit: Int = 8,
    val persistDebounce: Duration = 2.seconds,
)

data class FeedStatus(
    val daemonId: String? = null,
    /** A live frame has been applied in this session. */
    val live: Boolean = false,
    /** The daemon is still assembling its projection. */
    val projectionPending: Boolean = false,
    /**
     * Wall-clock time of the last applied workspace change; heartbeats never
     * advance it. It is restored with the cached projection after a restart.
     */
    val lastAppliedAt: Instant? = null,
)

/**
 * The attached machine's durable change stream. Only one feed runs; other
 * machines' state arrives through [DirectoryPoller] and never moves the feed.
 */
class Feed(
    val daemonId: String,
    private val sessions: MachineSessions,
    private val storage: CoreStorage,
    private val store: WorkspaceStore,
    private val scope: CoroutineScope,
    private val config: FeedConfig,
    private val clock: Clock,
    private val logger: CoreLogger,
) {
    private val file = "feed-${CoreStorage.safeName(daemonId)}.pb"
    /** The last applied change's time, in epoch milliseconds, kept beside the projection it describes. */
    private val appliedFile = "feed-${CoreStorage.safeName(daemonId)}.applied"
    private val replica: SyncReplica
    private var persistJob: Job? = null
    private var dirty = false
    private val mutableStatus = MutableStateFlow(FeedStatus(daemonId = daemonId))
    val status: StateFlow<FeedStatus> = mutableStatus.asStateFlow()

    init {
        val cached = runCatching { storage.read(file)?.let(SyncFrame.ADAPTER::decode) }
            .onFailure { logger.warn(TAG, "discarding unreadable feed cache for $daemonId", it) }
            .getOrNull()
        replica = SyncReplica(cached?.snapshot, cached?.cursor)
        if (cached?.snapshot != null) {
            val applied = runCatching { storage.read(appliedFile)?.decodeToString()?.trim()?.toLongOrNull() }.getOrNull()
            if (applied != null && applied > 0) mutableStatus.update { it.copy(lastAppliedAt = Instant.fromEpochMilliseconds(applied)) }
        }
    }

    /** Renders the persisted projection before any network access. */
    fun restoreCached() {
        val snapshot = replica.snapshot ?: return
        apply(snapshot)
    }

    /** Runs WatchSync until the stream fails or goes silent. Never returns normally. */
    suspend fun run(): Nothing = coroutineScope {
        mutableStatus.update { it.copy(live = false) }
        sessions.call(daemonId) { client ->
            val call = client.WatchSync()
            val frames = call.executeIn(
                this,
                SyncRequest(
                    after = replica.cursor,
                    conversation_limit = config.conversationLimit,
                    recent_conversation_limit = config.recentConversationLimit,
                    heartbeat_ms = config.heartbeat.inWholeMilliseconds.toInt(),
                ),
            )
            try {
                while (true) {
                    val received = withTimeoutOrNull(config.staleAfter) { frames.receiveCatching() }
                        ?: throw CoreException(FailureKind.TRANSIENT, "The sync stream went silent.")
                    val frame = received.getOrNull()
                        ?: throw received.exceptionOrNull() ?: CoreException(FailureKind.TRANSIENT, "The sync stream ended.")
                    val change = replica.apply(frame)
                    mutableStatus.update {
                        it.copy(
                            live = it.live || !frame.projection_pending,
                            projectionPending = frame.projection_pending,
                            lastAppliedAt = if (change.projection) clock.now() else it.lastAppliedAt,
                        )
                    }
                    if (change.projection) replica.snapshot?.let(::apply)
                    if (change.any) schedulePersist()
                }
            } finally {
                call.cancel()
            }
        }
        throw CoreException(FailureKind.TRANSIENT, "The sync stream ended.")
    }

    private fun apply(snapshot: GlobalSnapshot) {
        store.applyMachines(listOf(snapshot.state.toMachineSnapshot(daemonId)))
        store.applyFeedExtras(snapshot.settings, snapshot.conversations)
    }

    private fun schedulePersist() {
        dirty = true
        if (persistJob?.isActive == true) return
        persistJob = scope.launch {
            delay(config.persistDebounce)
            flush()
        }
    }

    /** Drops unsaved changes: its cache is being removed and must not be written again. */
    fun discard() {
        persistJob?.cancel()
        persistJob = null
        dirty = false
    }

    /**
     * Writes the applied projection and its cursor together, so a restart
     * never pairs them wrongly, then the time of the last applied change.
     */
    fun flush() {
        if (!dirty) return
        dirty = false
        val snapshot = replica.snapshot ?: return
        runCatching {
            storage.write(file, SyncFrame.ADAPTER.encode(SyncFrame(cursor = replica.cursor, snapshot = snapshot)))
            mutableStatus.value.lastAppliedAt?.let { storage.write(appliedFile, it.toEpochMilliseconds().toString().encodeToByteArray()) }
        }.onFailure { logger.warn(TAG, "could not persist the feed projection", it) }
    }

    private companion object {
        const val TAG = "Feed"
    }
}

fun State?.toMachineSnapshot(daemonId: String, unchanged: Boolean = false): MachineSnapshot {
    val state = this ?: State()
    return MachineSnapshot(
        daemonId = daemonId, projects = state.projects, boards = state.boards, cards = state.cards,
        chats = state.chats, archives = state.archives ?: SharedArchives(), unchanged = unchanged,
    )
}
