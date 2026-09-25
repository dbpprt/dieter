package com.dbpprt.dieter.connection

import com.dbpprt.dieter.v1.Project
import com.dbpprt.dieter.v1.Board
import com.dbpprt.dieter.v1.Card

// These unions are a client cache of eventual replicas. Execution still uses
// immutable owner IDs; neither snapshot provenance nor list position is an owner.
// A refreshed observation replaces the cache even if its wall-clock timestamp
// is smaller: the peer store, not client clocks, resolves concurrent edits.
internal fun sharedProjects(values: List<Project>): List<Project> = values.groupBy { it.id }.map { (_, versions) ->
    val selected = versions.last()
    val checkouts = versions.flatMap { it.checkoutsList }.groupBy { it.id }.map { (_, copies) ->
        val checkout = copies.lastOrNull { it.detached } ?: copies.last()
        val local = copies.lastOrNull { it.path.isNotEmpty() }
        checkout.toBuilder().setPath(local?.path.orEmpty()).clearValidationCommands().addAllValidationCommands(local?.validationCommandsList.orEmpty()).build()
    }.sortedBy { it.id }
    selected.toBuilder().clearCheckouts().addAllCheckouts(checkouts).build()
}.sortedBy { it.name.lowercase() }

internal fun sharedBoards(values: List<Board>): List<Board> = values.groupBy { it.id }.values.map { it.last() }.sortedBy { it.id }

/**
 * Full card projections are available only from a conversation's immutable
 * owner. Other replicas deliberately expose only peer-safe identity,
 * placement, lifecycle and label fields. Keep the latest replica projection
 * for those shared fields, then restore owner-only details from the last
 * authoritative owner observation.
 */
internal fun sharedItems(
    values: List<Card>,
    ownerDetails: Map<String, Card> = emptyMap(),
): List<Card> = values.groupBy { it.id }.values.map { versions ->
    val accepted = versions.filter { it.ownerDaemonId.isNotEmpty() }
    val replica = (if (accepted.isEmpty()) versions else accepted).reduce { previous, incoming -> mergeCardState(incoming, previous) }
    val owner = ownerDetails[replica.id]
        ?.takeIf { it.ownerDaemonId.isNotEmpty() && it.ownerDaemonId == replica.ownerDaemonId }
    if (owner == null) replica else {
        val merged = mergeCardState(replica.withOwnerDetails(owner), owner)
        if (merged.runtimeUpdatedAt == owner.runtimeUpdatedAt) merged
        else merged.toBuilder().clearActiveSubagents().build()
    }
}.sortedBy { it.id }

/**
 * Start from the owner projection so new owner-local fields are retained by
 * default. Overlay every field in the peer-store item contract from the
 * selected replica so cross-machine title, placement and lifecycle changes
 * remain current. Keep this list aligned with peerstore.DomainFields["item"].
 */
private fun Card.withOwnerDetails(owner: Card): Card {
    require(id == owner.id) { "Owner details belong to another card" }
    return owner.toBuilder()
        .setId(id)
        .setProjectId(projectId)
        .setOwnerDaemonId(ownerDaemonId)
        .setCheckoutId(checkoutId)
        .setScope(scope)
        .setCreatedAt(createdAt)
        .setTitle(title)
        .setBoardId(boardId)
        .setLane(lane)
        .setPosition(position)
        .setOrderKey(orderKey)
        .setPhaseChangedAt(phaseChangedAt)
        .setArchived(archived)
        .setPinned(pinned)
        .setDoneArchiveExempt(doneArchiveExempt)
        .setRuntime(runtime)
        .setRuntimeUpdatedAt(runtimeUpdatedAt)
        .setLastActivityAt(lastActivityAt)
        .setResponseSeq(responseSeq)
        .setResponseMessageId(responseMessageId)
        .setSeenResponseSeq(seenResponseSeq)
        .setProvider(provider)
        .setModel(model)
        .setEffort(effort)
        .setInitialPromptSentAt(initialPromptSentAt)
        .setMergedIntoCardId(mergedIntoCardId)
        .clearStateFields().addAllStateFields(stateFieldsList)
        .setPlacementRevision(placementRevision)
        .clearConflictKeys().addAllConflictKeys(conflictKeysList)
        .clearLabelIds().addAllLabelIds(labelIdsList)
        .build()
}

/** Thread-safe cache whose entries can only be replaced by their owner daemon. */
internal class OwnerCardDirectory {
    private val values = linkedMapOf<String, Card>()

    @Synchronized
    fun seed(cards: List<Card>) {
        cards.filter { it.id.isNotEmpty() && it.ownerDaemonId.isNotEmpty() }
            .forEach { values.putIfAbsent(it.id, it) }
    }

    @Synchronized
    fun replace(ownerDaemonId: String, cards: List<Card>): Map<String, Card> {
        if (ownerDaemonId.isBlank()) return values.toMap()
        val owned = cards.filter { it.ownerDaemonId == ownerDaemonId }.associateBy { it.id }
        values.entries.removeAll { (id, card) -> card.ownerDaemonId == ownerDaemonId && id !in owned }
        values.putAll(owned)
        return values.toMap()
    }

    @Synchronized
    fun snapshot(): Map<String, Card> = values.toMap()

    @Synchronized
    fun clear() = values.clear()
}
