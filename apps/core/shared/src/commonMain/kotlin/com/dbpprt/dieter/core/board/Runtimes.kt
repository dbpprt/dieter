package com.dbpprt.dieter.core.board

import com.dbpprt.dieter.api.v1.Card

/** What an agent runtime value means. One classifier replaces the clients' many ad hoc sets. */
enum class RuntimeState {
    IDLE,

    /** A turn is admitted, running, or streaming. */
    ACTIVE,

    /** A cancel was requested and the turn is winding down; still active. */
    STOPPING,

    /** The agent waits for the user, e.g. an approval. */
    NEEDS_INPUT,
    FAILED,
}

/** A client-side operation in flight for one card. */
enum class CardOperation { STARTING, MOVING, CANCELLING, LABELING, PINNING, RENAMING, UPDATING, ARCHIVING, MERGING, FORKING, READING }

object Runtimes {
    private val active = setOf("starting", "running", "working", "streaming", "active")
    private val needsInput = setOf("waiting", "waiting_for_user", "needs_input")
    private val failed = setOf("failed", "error")

    fun classify(runtime: String?): RuntimeState {
        val value = runtime?.trim()?.lowercase().orEmpty()
        return when {
            value == "cancelling" -> RuntimeState.STOPPING
            value in active -> RuntimeState.ACTIVE
            value in needsInput -> RuntimeState.NEEDS_INPUT
            value in failed -> RuntimeState.FAILED
            else -> RuntimeState.IDLE
        }
    }

    fun isActive(runtime: String?): Boolean = classify(runtime).let { it == RuntimeState.ACTIVE || it == RuntimeState.STOPPING }

    /** A board card's runtime badge, independent of its lane (a card can keep working in Review); null when idle. */
    fun badge(runtime: String, operation: CardOperation? = null): String? = when {
        operation == CardOperation.CANCELLING -> "Stopping…"
        operation == CardOperation.STARTING -> "Starting…"
        runtime.trim().equals("starting", ignoreCase = true) -> "Starting…"
        classify(runtime) == RuntimeState.STOPPING -> "Stopping…"
        classify(runtime) == RuntimeState.ACTIVE -> "Running"
        else -> null
    }

    /**
     * Whether the card's agent is working: its runtime, its conversation's
     * status, or a start or cancel this client has in flight. Never inferred
     * from the lane.
     */
    fun isActive(card: Card, conversationStatus: String? = null, operation: CardOperation? = null): Boolean =
        operation == CardOperation.STARTING || operation == CardOperation.CANCELLING ||
            isActive(card.runtime) || isActive(conversationStatus)

    /** Board status also counts running delegated agents. */
    fun isBoardActive(card: Card, conversationStatus: String? = null, operation: CardOperation? = null): Boolean =
        isActive(card, conversationStatus, operation) || card.active_subagents.any { isActive(it.status) || it.status.equals("pending", ignoreCase = true) }

    /** Git operations wait while the agent works or waits for input. */
    fun blocksWorkspace(card: Card, conversationStatus: String? = null, operation: CardOperation? = null): Boolean =
        isActive(card, conversationStatus, operation) ||
            classify(card.runtime) == RuntimeState.NEEDS_INPUT || classify(conversationStatus) == RuntimeState.NEEDS_INPUT

    /**
     * The runtime to display: a local start or cancel wins, then an active
     * conversation status, then an active card runtime, then any known value.
     */
    fun resolved(cardRuntime: String?, conversationStatus: String?, operation: CardOperation? = null): String {
        if (operation == CardOperation.STARTING) return "starting"
        if (operation == CardOperation.CANCELLING) return "cancelling"
        val status = conversationStatus?.trim().orEmpty()
        val runtime = cardRuntime?.trim().orEmpty()
        return when {
            isActive(status) -> status.lowercase()
            isActive(runtime) -> runtime.lowercase()
            runtime.isNotEmpty() -> runtime.lowercase()
            status.isNotEmpty() -> status.lowercase()
            else -> "idle"
        }
    }

    /** Unread means the daemon produced a reply the user has not seen. */
    fun isUnread(card: Card): Boolean = card.response_seq > card.seen_response_seq
}
