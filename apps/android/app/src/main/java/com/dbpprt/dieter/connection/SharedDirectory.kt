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

internal fun mergeBoardLifecycle(incoming: Board, previous: Board): Board {
    fun covers(a: Map<String, Long>, b: Map<String, Long>) = b.all { (actor, count) -> (a[actor] ?: 0) >= count }
    val all = previous.retirementVersionsList + incoming.retirementVersionsList
    val frontier = all.filterIndexed { i, version ->
        all.withIndex().none { (j, other) -> i != j && covers(other.clockMap, version.clockMap) &&
            (!covers(version.clockMap, other.clockMap) || other.rank > version.rank || other.rank == version.rank && j < i) }
    }.sortedBy { it.rank }
    if (frontier.size > 16 || previous.retirementRevision == "overflow") return previous.toBuilder().setRetirementRevision("overflow").setRetired(false).setRetirementBlocked(true).build()
    fun same(board: Board) = board.retirementVersionsList.sortedBy { it.rank } == frontier
    val requested = frontier.any { it.retired && !it.deleted }
    val references = if (requested) (incoming.retirementReferencesList + previous.retirementReferencesList).distinct().sorted().take(64) else emptyList()
    val blocked = requested && (frontier.size != 1 || references.isNotEmpty() || same(incoming) && incoming.retirementBlocked || same(previous) && previous.retirementBlocked)
    return incoming.toBuilder().clearRetirementVersions().addAllRetirementVersions(frontier)
        .setRetirementRevision(if (same(incoming)) incoming.retirementRevision else if (same(previous)) previous.retirementRevision else "unobserved-join")
        .setRetired(requested && !blocked).setRetirementBlocked(blocked)
        .clearRetirementReferences().addAllRetirementReferences(references).build()
}

internal data class BoardDirectory(val active: List<Board>, val retired: List<Board>)

internal fun sharedBoardDirectory(values: List<Board>, items: List<Card> = emptyList()): BoardDirectory {
    val references = items.flatMap { card -> listOf(card.boardId) + card.stateFieldsList.filter { it.name == "placement" }
        .flatMap { field -> field.versionsList.filterNot { it.deleted }.map { it.value.boardId } } }.toSet()
    val boards = values.groupBy { it.id }.values.map { copies -> copies.reduce { old, new -> mergeBoardLifecycle(new, old) } }
        .map { if (it.retired && it.id in references) it.toBuilder().setRetired(false).setRetirementBlocked(true).build() else it }.sortedBy { it.id }
    return BoardDirectory(boards.filterNot { it.retired }, boards.filter { it.retired })
}

internal fun sharedBoards(values: List<Board>): List<Board> = sharedBoardDirectory(values).active

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
