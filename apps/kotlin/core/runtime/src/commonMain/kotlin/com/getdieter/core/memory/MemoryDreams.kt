package com.getdieter.core.memory

import com.getdieter.api.v1.Card
import com.getdieter.api.v1.MemoryDream
import com.getdieter.client.v1.ConversationMemory
import com.getdieter.client.v1.MemoryDreamState
import com.getdieter.core.outbox.OutboxPolicy

/**
 * Dreams as their conversation's banner shows them: what happened, what changed, and which of
 * Apply, Discard and Undo apply now. Statuses are the daemon's (`internal/host/memory/dreams.go`).
 */
object MemoryDreams {
    const val RUNNING = "running"
    const val STAGED = "staged"
    const val APPLIED = "applied"
    const val DISCARDED = "discarded"
    const val UNDONE = "undone"
    const val EMPTY = "empty"
    const val FAILED = "failed"

    /** Card.memory_role of a dream conversation. */
    const val DREAMER = "dreamer"

    /** [dream] laid out for its banner. */
    fun state(dream: MemoryDream): MemoryDreamState {
        val status = dream.status
        return MemoryDreamState(
            card_id = dream.card_id,
            status = status,
            running = status == RUNNING,
            title = title(status),
            counts_label = countsLabel(dream),
            detail = detail(status),
            can_apply = status == STAGED,
            can_discard = status == STAGED,
            can_undo = status == APPLIED,
            error =
                if (status == FAILED) dream.error.ifBlank { "The dream did not finish." } else "",
            dream = dream,
        )
    }

    /** "Dreaming…", "Dream awaiting review", "Dream applied", ... */
    fun title(status: String): String =
        when (status) {
            RUNNING -> "Dreaming…"
            STAGED -> "Dream awaiting review"
            APPLIED -> "Dream applied"
            DISCARDED -> "Dream discarded"
            UNDONE -> "Dream undone"
            EMPTY -> "Dream found nothing to change"
            FAILED -> "Dream failed"
            else -> "Dream"
        }

    /**
     * "2 added · 1 merged · 3 verified"; "No changes" once a finished dream changed nothing; empty
     * while it runs without changes or when it failed.
     */
    fun countsLabel(dream: MemoryDream): String {
        val counts =
            listOf(
                    dream.added to "added",
                    dream.merged to "merged",
                    dream.superseded to "superseded",
                    dream.retired to "retired",
                    dream.verified to "verified",
                )
                .filter { it.first > 0 }
                .joinToString(" · ") { "${it.first} ${it.second}" }
        return when {
            counts.isNotEmpty() -> counts
            dream.status == RUNNING || dream.status == FAILED -> ""
            else -> "No changes"
        }
    }

    /** What the banner's actions do now; empty when none applies. */
    fun detail(status: String): String =
        when (status) {
            STAGED -> "Apply the changes to the project's saved memories, or discard them."
            APPLIED -> "Undo restores the memories this dream changed."
            UNDONE -> "The memories this dream changed are restored."
            else -> ""
        }

    /**
     * [card]'s memory as its conversation shows it. [projectEnabled] is its project's switch,
     * [enabled] the conversation's as this client shows it, [dream] its dream once read. A dream
     * always has memory and no switch; the switch needs the project's memory and the conversation
     * on its machine and not archived.
     */
    fun conversation(
        card: Card,
        projectEnabled: Boolean,
        enabled: Boolean = card.memory,
        dream: MemoryDream? = null,
    ): ConversationMemory {
        val dreamer = card.memory_role == DREAMER
        val shown = projectEnabled && !dreamer
        return ConversationMemory(
            enabled = dreamer || enabled,
            shown = shown,
            can_toggle = shown && OutboxPolicy.isServerBacked(card.id) && !card.archived,
            dreamer = dreamer,
            dream = if (dreamer) dream?.takeIf { it.card_id == card.id }?.let(::state) else null,
        )
    }
}
