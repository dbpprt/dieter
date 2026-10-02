package com.dbpprt.dieter.core.sync

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.BoardRetirementVersion
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Checkout
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.api.v1.SharedArchives
import com.dbpprt.dieter.core.board.Cards

/**
 * One machine's view of the shared workspace: its live feed (attached
 * machine) or its latest `GetState(all_projects)` (other machines).
 */
data class MachineSnapshot(
    /** The daemon that served this view. */
    val daemonId: String,
    val projects: List<Project>,
    val boards: List<Board>,
    val cards: List<Card>,
    val chats: List<Card>,
    val archives: SharedArchives = SharedArchives(),
    /** A conditional read that found nothing new; ignored by the reducer. */
    val unchanged: Boolean = false,
)

/** The merged, account-wide directory every view derives from. */
data class DirectoryProjection(
    val projects: Map<String, Project> = emptyMap(),
    /** Project ID → the machine whose snapshot last listed it. */
    val projectReplicas: Map<String, String> = emptyMap(),
    val boards: Map<String, List<Board>> = emptyMap(),
    val retiredBoards: Map<String, Board> = emptyMap(),
    /** Project ID → board cards (and chats filed on a board), sorted by ID. */
    val cards: Map<String, List<Card>> = emptyMap(),
    /** Unfiled chats, newest activity first. */
    val chats: List<Card> = emptyList(),
) {
    val allItems: List<Card> get() = cards.values.flatten() + chats

    fun board(id: String): Board? = boards.values.firstNotNullOfOrNull { list -> list.firstOrNull { it.id == id } }

    fun item(id: String): Card? = cards.values.firstNotNullOfOrNull { list -> list.firstOrNull { it.id == id } }
        ?: chats.firstOrNull { it.id == id }

    /** The machine that holds [projectId]'s checkout [checkoutId]. */
    fun checkoutMachine(projectId: String, checkoutId: String): String? =
        projects[projectId]?.checkouts?.firstOrNull { it.id == checkoutId }?.daemon_id?.ifEmpty { null }

    /** The machine that runs [card]'s conversation: its recorded owner, else its checkout's machine. */
    fun owner(card: Card): String? = card.owner_daemon_id.ifEmpty { null } ?: checkoutMachine(card.project_id, card.checkout_id)

    companion object {
        val EMPTY = DirectoryProjection()
    }
}

/** Merges machine snapshots into the directory. */
object DirectoryReducer {
    fun merge(current: DirectoryProjection, snapshots: List<MachineSnapshot>): DirectoryProjection {
        val changed = snapshots.filterNot { it.unchanged }
        if (changed.isEmpty()) return current
        val refreshed = changed.map { it.daemonId }.toSet()
        val incomingIds = changed.flatMap { snapshot -> snapshot.projects.map { it.id } }.toSet()
        val projects = current.projects.toMutableMap()
        val projectReplicas = current.projectReplicas.toMutableMap()
        // A project absent from its refreshed replica has left that catalog. A
        // shared project present in another snapshot keeps its owned items.
        for (id in current.projects.keys) {
            if (id !in incomingIds && current.projectReplicas[id] in refreshed) {
                projects.remove(id)
                projectReplicas.remove(id)
            }
        }
        val known = current.allItems + changed.flatMap { it.cards + it.chats }
        val removed = changed.flatMap { it.archives.item_ids }.toMutableSet()
        val archivedProjects = changed.flatMap { it.archives.project_ids }.toSet()
        for (snapshot in changed) {
            val present = (snapshot.cards + snapshot.chats).map { it.id }.toSet()
            // Only an owner's complete snapshot can retire a missing item.
            known.filter { it.owner_daemon_id == snapshot.daemonId && it.id !in present }.mapTo(removed) { it.id }
        }
        val items = LinkedHashMap<String, Card>()
        for (item in current.allItems) items[item.id] = item
        val allBoards = LinkedHashMap(current.retiredBoards)
        for (board in current.boards.values.flatten()) allBoards[board.id] = board
        for (snapshot in changed) {
            for (project in snapshot.projects) {
                projects[project.id] = mergeProject(projects[project.id], project)
                projectReplicas[project.id] = snapshot.daemonId
            }
            for (board in snapshot.boards + snapshot.archives.retired_boards) {
                allBoards[board.id] = mergeBoardLifecycle(board, allBoards[board.id])
            }
            for (item in snapshot.cards + snapshot.chats) {
                items[item.id] = retainingOwnerDetails(item, items[item.id], snapshot.daemonId)
            }
        }
        for (id in archivedProjects) {
            projects.remove(id)
            projectReplicas.remove(id)
        }
        val visible = items.values.filter {
            (it.id !in removed || (it.archived && Cards.isChat(it))) && projects.containsKey(it.project_id)
        }
        val referenced = referencedBoards(items.values)
        val boards = HashMap<String, MutableList<Board>>()
        val retired = HashMap<String, Board>()
        for (candidate in allBoards.values) {
            if (!projects.containsKey(candidate.project_id)) continue
            val board = blockingReferenced(candidate, referenced)
            if (board.retired) retired[board.id] = board else boards.getOrPut(board.project_id) { mutableListOf() }.add(board)
        }
        val sortedBoards = boards.mapValues { (_, list) -> list.sortedBy { it.id } }
        for ((id, project) in projects) projects[id] = project.copy(board_count = sortedBoards[id]?.size ?: 0)
        val (chats, boardItems) = visible.partition(Cards::isChat)
        return DirectoryProjection(
            projects = projects,
            projectReplicas = projectReplicas,
            boards = sortedBoards,
            retiredBoards = retired,
            cards = boardItems.sortedBy { it.id }.groupBy { it.project_id },
            chats = chats.sortedWith(compareByDescending<Card> { activityTime(it) }.thenBy { it.id }),
        )
    }

    fun activityTime(card: Card): String = card.last_activity_at.ifEmpty { card.updated_at }

    /** Boards a card is filed on or holds a live placement on. */
    fun referencedBoards(items: Iterable<Card>): Set<String> = items.flatMapTo(HashSet()) { card ->
        listOf(card.board_id) + card.state_fields.filter { it.name == "placement" }
            .flatMap { field -> field.versions.filterNot { it.deleted }.map { it.value_?.board_id.orEmpty() } }
    }

    /** A retired board that a card still references stays shown, its retirement blocked. */
    fun blockingReferenced(board: Board, referenced: Set<String>): Board =
        if (board.retired && board.id in referenced) board.copy(retired = false, retirement_blocked = true) else board

    /** Whether [board]'s lifecycle already includes every retirement intent of [other]. */
    fun coversLifecycle(board: Board, other: Board): Boolean =
        other.retirement_versions.all { version -> board.retirement_versions.any { covers(it.clock, version.clock) } }

    /**
     * Folds one card observed outside a machine snapshot, such as the fresh
     * `detail.card` of a conversation read from its owner, into the directory
     * without treating it as a complete owner view.
     */
    fun foldItem(current: DirectoryProjection, incoming: Card, sourceDaemonId: String?): DirectoryProjection {
        if (!current.projects.containsKey(incoming.project_id)) return current
        val existing = current.allItems.firstOrNull { it.id == incoming.id }
        val merged = retainingOwnerDetails(incoming, existing, sourceDaemonId)
        if (merged == existing) return current
        val cards = current.cards.mapValues { (_, items) -> items.filterNot { it.id == merged.id } }.toMutableMap()
        var chats = current.chats.filterNot { it.id == merged.id }
        if (!Cards.isChat(merged)) {
            cards[merged.project_id] = (cards[merged.project_id].orEmpty() + merged).sortedBy { it.id }
        } else {
            chats = (chats + merged).sortedWith(compareByDescending<Card> { activityTime(it) }.thenBy { it.id })
        }
        return current.copy(cards = cards.filterValues { it.isNotEmpty() }, chats = chats)
    }

    /**
     * Only the execution owner serves the full card. A peer omits the prompt,
     * rendered summary, workspace, and usage; those empty fields must not erase
     * an earlier owner observation. Shared fields follow the peer projection,
     * whose conflicts the daemon resolves, not client wall clocks.
     */
    fun retainingOwnerDetails(incoming: Card, previous: Card?, sourceDaemonId: String?): Card {
        if (previous == null || previous.id != incoming.id || incoming.owner_daemon_id.isEmpty() ||
            previous.owner_daemon_id != incoming.owner_daemon_id ||
            (sourceDaemonId == incoming.owner_daemon_id && !hasOlderRuntime(incoming, previous))
        ) {
            return mergeCardState(incoming, previous)
        }
        // Start from the full card so owner-local fields are kept, then overlay
        // the peer-store item contract (peerstore.DomainFields["item"]).
        val overlay = previous.copy(
            id = incoming.id, project_id = incoming.project_id, owner_daemon_id = incoming.owner_daemon_id,
            checkout_id = incoming.checkout_id, scope = incoming.scope, created_at = incoming.created_at,
            title = incoming.title, board_id = incoming.board_id, lane = incoming.lane, position = incoming.position,
            order_key = incoming.order_key, phase_changed_at = incoming.phase_changed_at, archived = incoming.archived,
            pinned = incoming.pinned, done_archive_exempt = incoming.done_archive_exempt, runtime = incoming.runtime,
            response_seq = incoming.response_seq, response_message_id = incoming.response_message_id,
            seen_response_seq = incoming.seen_response_seq, runtime_updated_at = incoming.runtime_updated_at,
            last_activity_at = incoming.last_activity_at, provider = incoming.provider, model = incoming.model,
            effort = incoming.effort, initial_prompt_sent_at = incoming.initial_prompt_sent_at,
            merged_into_card_id = incoming.merged_into_card_id, placement_revision = incoming.placement_revision,
            conflict_keys = incoming.conflict_keys, label_ids = incoming.label_ids, state_fields = incoming.state_fields,
        )
        val merged = mergeCardState(overlay, previous)
        // Owner-only subagent activity belongs to that runtime observation.
        return if (merged.runtime_updated_at != previous.runtime_updated_at) merged.copy(active_subagents = emptyList()) else merged
    }

    /** Checkouts union across replicas; a detached checkout stays detached, and paths are kept from whoever has them. */
    fun mergeProject(previous: Project?, incoming: Project): Project {
        if (previous == null) return incoming
        val checkouts = LinkedHashMap<String, Checkout>()
        for (checkout in previous.checkouts) checkouts[checkout.id] = checkout
        for (checkout in incoming.checkouts) {
            val prior = checkouts[checkout.id]
            if (prior?.detached == true && !checkout.detached) continue
            checkouts[checkout.id] = if (checkout.path.isEmpty()) {
                checkout.copy(path = prior?.path.orEmpty(), validation_commands = prior?.validation_commands.orEmpty())
            } else {
                checkout
            }
        }
        return incoming.copy(checkouts = checkouts.values.sortedBy { it.id })
    }

    /**
     * Board retirement is a causal intent. References and unresolved intents
     * keep a board visible; arrival order cannot retire it.
     */
    fun mergeBoardLifecycle(incoming: Board, previous: Board?): Board {
        if (previous == null || previous.id != incoming.id) return incoming
        val all = previous.retirement_versions + incoming.retirement_versions
        val frontier = all.filterIndexed { i, version ->
            all.withIndex().none { (j, other) ->
                i != j && covers(other.clock, version.clock) &&
                    (!covers(version.clock, other.clock) || other.rank > version.rank || (other.rank == version.rank && j < i))
            }
        }.sortedBy { it.rank }
        if (frontier.size > 16 || previous.retirement_revision == "overflow") {
            return incoming.copy(
                retirement_versions = previous.retirement_versions, retirement_revision = "overflow",
                retired = false, retirement_blocked = true,
            )
        }
        fun same(board: Board): Boolean = board.retirement_versions.sortedBy(BoardRetirementVersion::rank) == frontier
        val requested = frontier.any { it.retired && !it.deleted }
        val references = (previous.retirement_references + incoming.retirement_references).distinct().sorted().take(64)
        val blocked = requested && (
            frontier.size != 1 || references.isNotEmpty() ||
                (same(incoming) && incoming.retirement_blocked) || (same(previous) && previous.retirement_blocked)
            )
        return incoming.copy(
            retirement_versions = frontier,
            retirement_revision = when {
                same(incoming) -> incoming.retirement_revision
                same(previous) -> previous.retirement_revision
                else -> UNOBSERVED_JOIN
            },
            retirement_blocked = blocked,
            retirement_references = if (requested) references else emptyList(),
            retired = requested && !blocked,
        )
    }
}
