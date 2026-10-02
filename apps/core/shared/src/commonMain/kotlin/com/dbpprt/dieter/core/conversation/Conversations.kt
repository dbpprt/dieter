package com.dbpprt.dieter.core.conversation

import com.dbpprt.dieter.api.v1.Harness
import com.dbpprt.dieter.core.board.BoardOperations
import com.dbpprt.dieter.core.composition.ConversationDrafts
import com.dbpprt.dieter.core.outbox.Outbox
import com.dbpprt.dieter.core.platform.DeviceSettings
import com.dbpprt.dieter.core.runtime.CoreLogger
import com.dbpprt.dieter.core.session.MachineSessions
import com.dbpprt.dieter.core.store.WorkspaceStore
import com.dbpprt.dieter.core.sync.FeedStatus
import kotlin.time.Clock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Open conversations, bounded to [ConversationConfig.maxOpen] live streams,
 * plus a small cache so reopening shows the last transcript at once, and
 * the device's reasoning-trace preference, kept in [settings]. Confined to
 * the core dispatcher.
 */
class Conversations(
    private val sessions: MachineSessions,
    private val store: WorkspaceStore,
    private val outbox: Outbox,
    private val board: BoardOperations,
    private val drafts: ConversationDrafts,
    private val feed: StateFlow<FeedStatus>,
    private val config: ConversationConfig,
    private val clock: Clock,
    private val logger: CoreLogger,
    private val scope: CoroutineScope,
    private val settings: DeviceSettings? = null,
    /** A machine's agent catalog once it has loaded, else null. */
    private val catalog: (daemonId: String) -> List<Harness>? = { null },
) {
    private val open = LinkedHashMap<String, ConversationSession>()
    private val cache = LinkedHashMap<String, TranscriptState>()
    private val mutableShowReasoning = MutableStateFlow(settings?.string(SHOW_REASONING)?.toBooleanStrictOrNull() ?: false)

    /** Transcripts on this device show reasoning traces; off unless the user turned them on. */
    val showReasoning: StateFlow<Boolean> = mutableShowReasoning.asStateFlow()

    /** Shows or hides reasoning traces on this device and remembers the choice. */
    fun setShowReasoning(show: Boolean) {
        settings?.putString(SHOW_REASONING, show.toString())
        mutableShowReasoning.value = show
    }

    /** Opens [cardId] (a server or local ID) or returns the session already open for it. */
    fun open(cardId: String): ConversationSession {
        val id = outbox.view.value.resolve(cardId)
        open.remove(key(id))?.let { existing ->
            open[id] = existing
            return existing
        }
        val cached = cache[id] ?: store.state.value.conversations[id]?.let { TranscriptState(snapshot = it) }
        val session = ConversationSession(
            id, sessions, store, outbox, board, drafts, config, clock, logger, scope, cached,
            liveTailCurrent = { daemonId, card -> feed.value.let { it.live && it.daemonId == daemonId } && store.state.value.conversations.containsKey(card) },
            onTranscript = ::remember,
            catalog = catalog,
        )
        open[id] = session
        while (open.size > config.maxOpen) open.remove(open.keys.first())?.close()
        session.start()
        return session
    }

    fun session(cardId: String): ConversationSession? = open[key(outbox.view.value.resolve(cardId))]

    fun close(cardId: String) {
        open.remove(key(outbox.view.value.resolve(cardId)))?.close()
    }

    /**
     * The key [id] is open under. A conversation opened while it was still
     * being created stays keyed by its local ID after the outbox resolves it,
     * so its server ID must find it too.
     */
    private fun key(id: String): String =
        if (id in open) id else open.keys.firstOrNull { outbox.view.value.resolve(it) == id } ?: id

    /** Closes everything and forgets cached transcripts, e.g. when the account changes. */
    fun reset() {
        open.values.forEach(ConversationSession::close)
        open.clear()
        cache.clear()
    }

    private fun remember(cardId: String, transcript: TranscriptState) {
        cache.remove(cardId)
        cache[cardId] = transcript
        while (cache.size > config.cacheSize) cache.remove(cache.keys.first())
    }

    private companion object {
        /** The [DeviceSettings] key of the reasoning-trace preference. */
        const val SHOW_REASONING = "conversations.show_reasoning"
    }
}
