package com.dbpprt.dieter.core.sync

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.GlobalDelta
import com.dbpprt.dieter.api.v1.GlobalSnapshot
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.api.v1.State
import com.dbpprt.dieter.api.v1.SyncCursor
import com.dbpprt.dieter.api.v1.SyncFrame

/**
 * One daemon's durable metadata projection, fed by WatchSync. Not thread-safe;
 * the core confines it to the sync coroutine.
 */
class SyncReplica(snapshot: GlobalSnapshot? = null, cursor: SyncCursor? = null) {
    var snapshot: GlobalSnapshot? = snapshot
        private set
    var cursor: SyncCursor? = cursor
        private set

    // Frames received while the daemon reports projection_pending are buffered,
    // so a partially built projection is never shown or persisted as applied.
    private var pending: GlobalSnapshot? = null

    data class Change(val projection: Boolean, val cursor: Boolean) {
        val any get() = projection || cursor
    }

    fun apply(frame: SyncFrame): Change {
        // A transport heartbeat never advances the applied cursor.
        if (frame.transport_only || frame.heartbeat) return Change(projection = false, cursor = false)
        val incoming = frame.snapshot
        val delta = frame.delta
        if (frame.projection_pending) {
            val base = pending ?: snapshot
            pending = when {
                incoming != null -> incoming
                delta != null && base != null -> applyGlobalDelta(base, delta)
                else -> pending
            }
            val cleared = cursor != null
            cursor = null
            return Change(projection = false, cursor = cleared)
        }
        val buffered = pending
        pending = null
        val current = snapshot
        val next = when {
            incoming != null -> incoming
            buffered != null && delta != null -> applyGlobalDelta(buffered, delta)
            buffered != null -> buffered
            delta != null && current != null -> applyGlobalDelta(current, delta)
            else -> current
        }
        val projectionChanged = next != snapshot
        snapshot = next
        val cursorChanged = frame.cursor != null && frame.cursor != cursor
        if (cursorChanged) cursor = frame.cursor
        return Change(projectionChanged, cursorChanged)
    }
}

/**
 * Applies a delta to a persisted projection. Changed objects keep their
 * position and new ones are appended. The native clients disagree here today:
 * Swift replaces in place while Kotlin moves changed objects to the end.
 */
fun applyGlobalDelta(snapshot: GlobalSnapshot, delta: GlobalDelta): GlobalSnapshot {
    val state = snapshot.state ?: State()
    return snapshot.copy(
        state = state.copy(
            projects = mergeById(state.projects, delta.projects, delta.removed_project_ids, Project::id),
            boards = mergeById(state.boards, delta.boards, delta.removed_board_ids, Board::id),
            cards = mergeById(state.cards, delta.cards, delta.removed_card_ids, Card::id),
            chats = mergeById(state.chats, delta.chats, delta.removed_chat_ids, Card::id),
            archives = delta.archives ?: state.archives,
        ),
        conversations = mergeById(snapshot.conversations, delta.conversations, delta.removed_conversation_ids) {
            it.detail?.card?.id.orEmpty()
        },
        settings = delta.settings ?: snapshot.settings,
    )
}

private fun <T> mergeById(current: List<T>, changed: List<T>, removed: List<String>, id: (T) -> String): List<T> {
    if (changed.isEmpty() && removed.isEmpty()) return current
    val removedIds = removed.toSet()
    val replacements = changed.associateBy(id)
    val placed = HashSet<String>()
    val next = current.mapNotNull { value ->
        val key = id(value)
        when {
            key in removedIds -> null
            key in replacements -> replacements.getValue(key).also { placed += key }
            else -> value
        }
    }
    return next + changed.map(id).filter { it !in removedIds && placed.add(it) }.map(replacements::getValue)
}
