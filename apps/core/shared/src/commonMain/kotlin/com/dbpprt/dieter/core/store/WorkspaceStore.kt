package com.dbpprt.dieter.core.store

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Checkout
import com.dbpprt.dieter.api.v1.ConversationSnapshot
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.api.v1.Settings
import com.dbpprt.dieter.core.board.Cards
import com.dbpprt.dieter.core.runtime.Timestamps
import com.dbpprt.dieter.core.sync.DirectoryProjection
import com.dbpprt.dieter.core.sync.DirectoryReducer
import com.dbpprt.dieter.core.sync.MachineSnapshot
import com.dbpprt.dieter.core.sync.TranscriptFreshness
import kotlin.time.Clock
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** The account-wide workspace every client view derives from. */
data class WorkspaceView(
    val projects: List<Project> = emptyList(),
    val boards: Map<String, List<Board>> = emptyMap(),
    val retiredBoards: List<Board> = emptyList(),
    /** Project ID → board items, archived items excluded. */
    val cards: Map<String, List<Card>> = emptyMap(),
    /** Unfiled chats, newest activity first, archived excluded. */
    val chats: List<Card> = emptyList(),
    /** Project ID → the machine whose view last listed it. */
    val projectReplicas: Map<String, String> = emptyMap(),
    val settings: Settings? = null,
    /** Card ID → the feed's bounded conversation tail (recent and active cards). */
    val conversations: Map<String, ConversationSnapshot> = emptyMap(),
    /** Card IDs whose state includes an optimistic, not yet confirmed change. */
    val pendingCardIds: Set<String> = emptySet(),
    /** True once any machine's view (live or cached) has been applied. */
    val loaded: Boolean = false,
) {
    fun card(id: String): Card? = cards.values.firstNotNullOfOrNull { list -> list.firstOrNull { it.id == id } }
        ?: chats.firstOrNull { it.id == id }

    fun project(id: String): Project? = projects.firstOrNull { it.id == id }

    fun board(id: String): Board? = boards.values.firstNotNullOfOrNull { list -> list.firstOrNull { it.id == id } }

    val allItems: List<Card> get() = cards.values.flatten() + chats
}

/**
 * An optimistic change to one card, applied over the merged directory until
 * the directory reflects it or it is rolled back.
 */
interface CardOverlay {
    val operationId: String
    val cardId: String
    fun apply(card: Card): Card

    /** The directory already shows this change; the overlay can go. */
    fun satisfiedBy(card: Card): Boolean
}

/** A card or chat that exists only in the outbox so far. */
/**
 * A card that exists only locally. [aliases] are the IDs its synced copy may
 * appear under (the daemon's deterministic or acknowledged ID); once any of
 * them is listed, the synced copy replaces it, so the card never shows twice.
 */
data class PendingItem(val card: Card, val daemonId: String, val aliases: Set<String> = emptySet())

/**
 * The single reducer for workspace state. Machine snapshots, feed extras,
 * conversation-sourced card details, and optimistic overlays all enter here;
 * views never keep their own copies. Confined to the core dispatcher.
 */
class WorkspaceStore(private val clock: Clock = Clock.System) {
    private var directory = DirectoryProjection.EMPTY

    /** [directory] with the administrative results no machine view shows yet. */
    private var administered = DirectoryProjection.EMPTY
    private var settings: Settings? = null
    private var conversations: Map<String, ConversationSnapshot> = emptyMap()
    private val overlays = LinkedHashMap<String, CardOverlay>()
    private val confirmedAt = HashMap<String, Instant>()
    private val pendingItems = LinkedHashMap<String, PendingItem>()
    private val pendingProjects = LinkedHashMap<String, Project>()

    /** Project ID → the machine that holds a project no machine view lists yet. */
    private val pendingReplicas = LinkedHashMap<String, String>()

    /** Checkout ID → an attached, detached, or consolidated checkout. */
    private val pendingCheckouts = LinkedHashMap<String, Checkout>()

    /** Consolidated project ID → the project it was folded into. */
    private val pendingConsolidations = LinkedHashMap<String, String>()
    private val pendingBoards = LinkedHashMap<String, Board>()
    private var loaded = false
    private val mutableState = MutableStateFlow(WorkspaceView())
    val state: StateFlow<WorkspaceView> = mutableState.asStateFlow()

    private val mutableRevision = MutableStateFlow(0L)

    /** Advances whenever server-sourced state (directory or conversation tail) changes. */
    val revision: StateFlow<Long> = mutableRevision.asStateFlow()

    /**
     * The merged directory, with the projects, replicas, checkouts, and boards
     * administrative calls returned that no machine view shows yet, so a call
     * that follows one reaches the right machine. Cards are the directory's.
     */
    val directoryProjection: DirectoryProjection get() = administered

    fun applyMachines(snapshots: List<MachineSnapshot>) {
        val next = DirectoryReducer.merge(directory, snapshots)
        val changed = next != directory || !loaded
        directory = next
        loaded = loaded || snapshots.isNotEmpty()
        reconcile()
        if (changed) {
            mutableRevision.value++
            publish()
        }
    }

    /** The attached machine's settings and conversation tail from its feed. */
    fun applyFeedExtras(settings: Settings?, conversations: List<ConversationSnapshot>) {
        this.settings = settings ?: this.settings
        val merged = LinkedHashMap<String, ConversationSnapshot>()
        for (incoming in conversations) {
            val id = incoming.detail?.card?.id ?: continue
            merged[id] = TranscriptFreshness.freshest(this.conversations[id], incoming)
        }
        this.conversations = merged
        for (conversation in conversations) conversation.detail?.card?.let { card -> foldCardInternal(card, card.owner_daemon_id) }
        mutableRevision.value++
        publish()
    }

    /** Folds a card observed from its owner (e.g. a conversation read) into the directory. */
    fun foldCard(card: Card, sourceDaemonId: String?) {
        if (foldCardInternal(card, sourceDaemonId)) {
            reconcile()
            mutableRevision.value++
            publish()
        }
    }

    private fun foldCardInternal(card: Card, sourceDaemonId: String?): Boolean {
        val next = DirectoryReducer.foldItem(directory, card, sourceDaemonId)
        if (next == directory) return false
        directory = next
        return true
    }

    fun addOverlay(overlay: CardOverlay) {
        overlays[overlay.operationId] = overlay
        reconcile()
        publish()
    }

    /** The mutation reached the daemon; keep the overlay until the feed catches up. */
    fun confirmOverlay(operationId: String) {
        if (overlays.containsKey(operationId)) confirmedAt[operationId] = clock.now()
        reconcile()
        publish()
    }

    /** The mutation failed: restore the directory's value. */
    fun rollbackOverlay(operationId: String) {
        confirmedAt.remove(operationId)
        if (overlays.remove(operationId) != null) publish()
    }

    /**
     * Shows a project or board an administrative call returned until a machine
     * view is at least as new; another peer's later edit is never pinned.
     * [replicaDaemonId] is the machine that holds a project no view lists yet
     * (a project it just created); calls for the project are routed there.
     */
    fun overlayProject(project: Project, replicaDaemonId: String? = null) {
        pendingProjects[project.id] = project
        if (!replicaDaemonId.isNullOrEmpty()) pendingReplicas[project.id] = replicaDaemonId
        reconcile()
        publish()
    }

    /** A board as the client currently knows it: a pending response, the directory, or the retired list. */
    fun findBoard(id: String): Board? = pendingBoards[id] ?: directory.board(id) ?: directory.retiredBoards[id]

    /**
     * Shows a board an administrative call returned until a machine view is at
     * least as new and includes its retirement intent. Its lifecycle joins the
     * known one, and it lists as retired or live accordingly.
     */
    fun overlayBoard(board: Board) {
        pendingBoards[board.id] = board
        reconcile()
        publish()
    }

    /** Shows an attached or detached checkout on its project until a machine view lists it so. */
    fun overlayCheckout(checkout: Checkout) {
        pendingCheckouts[checkout.id] = checkout
        reconcile()
        publish()
    }

    /**
     * [sourceId] was folded into [destination]: the source leaves the
     * workspace, its boards and items show on the destination, and the
     * destination shows the checkouts the call returned, until no machine view
     * lists the source.
     */
    fun overlayConsolidation(sourceId: String, destination: Project) {
        pendingConsolidations[sourceId] = destination.id
        pendingProjects[destination.id] = destination
        for (checkout in destination.checkouts) pendingCheckouts[checkout.id] = checkout
        reconcile()
        publish()
    }

    fun setPendingItems(items: Map<String, PendingItem>) {
        if (items == pendingItems) return
        pendingItems.clear()
        pendingItems.putAll(items)
        publish()
    }

    fun clear() {
        directory = DirectoryProjection.EMPTY
        settings = null
        conversations = emptyMap()
        overlays.clear()
        confirmedAt.clear()
        pendingItems.clear()
        pendingProjects.clear()
        pendingReplicas.clear()
        pendingCheckouts.clear()
        pendingConsolidations.clear()
        pendingBoards.clear()
        loaded = false
        mutableRevision.value++
        publish()
    }

    /** Drops overlays the directory now reflects, or that were confirmed long enough ago. */
    private fun reconcile() {
        pendingProjects.entries.removeAll { (id, pending) ->
            directory.projects[id]?.let { Timestamps.compare(it.updated_at, pending.updated_at) >= 0 } == true
        }
        pendingReplicas.keys.removeAll { it in directory.projectReplicas }
        pendingCheckouts.values.removeAll { pending ->
            directory.projects[pending.project_id]?.checkouts?.any { it.id == pending.id && (it.detached || !pending.detached) } == true
        }
        pendingConsolidations.keys.removeAll { it !in directory.projects }
        pendingBoards.entries.removeAll { (id, pending) ->
            // Retiring or restoring keeps the board's timestamp; its lifecycle shows the view has the intent.
            val known = directory.board(id) ?: directory.retiredBoards[id]
            known != null && Timestamps.compare(known.updated_at, pending.updated_at) >= 0 && DirectoryReducer.coversLifecycle(known, pending)
        }
        val now = clock.now()
        val iterator = overlays.entries.iterator()
        while (iterator.hasNext()) {
            val (id, overlay) = iterator.next()
            val card = directory.allItems.firstOrNull { it.id == overlay.cardId }
            val confirmed = confirmedAt[id]
            if ((card != null && overlay.satisfiedBy(card)) || (confirmed != null && now - confirmed > CONFIRMED_GRACE)) {
                iterator.remove()
                confirmedAt.remove(id)
            }
        }
    }

    private fun publish() {
        val byId = LinkedHashMap<String, Card>()
        for (item in directory.allItems) byId[item.id] = item
        val pendingIds = HashSet<String>()
        for (overlay in overlays.values) {
            val card = byId[overlay.cardId] ?: continue
            byId[overlay.cardId] = overlay.apply(card)
            pendingIds += overlay.cardId
        }
        for ((id, pending) in pendingItems) {
            if (!byId.containsKey(id) && pending.aliases.none(byId::containsKey)) {
                byId[id] = pending.card
                pendingIds += id
            }
        }
        administered = withAdministration(byId.values)
        // Archived items leave every live view; the Archive view reads them on demand.
        val live = byId.values.filterNot { it.archived }
        // A consolidated project's boards and items show on its destination.
        val moved = pendingConsolidations.isNotEmpty()
        val homed = if (!moved) live else live.map { card -> destinationOf(card.project_id).let { if (it == card.project_id) card else card.copy(project_id = it) } }
        val (chats, cards) = homed.partition(Cards::isChat)
        val boards = if (!moved) administered.boards else {
            administered.boards.values.flatten().map { it.copy(project_id = destinationOf(it.project_id)) }
                .groupBy { it.project_id }.mapValues { (_, list) -> list.sortedBy { it.id } }
        }
        val retired = administered.retiredBoards.values.map { if (moved) it.copy(project_id = destinationOf(it.project_id)) else it }
        // A project counts the live boards shown for it.
        val projects = administered.projects.values.filterNot { it.id in pendingConsolidations }.map { project ->
            val count = boards[project.id]?.size ?: 0
            if (project.board_count == count) project else project.copy(board_count = count)
        }.sortedWith(compareBy<Project> { it.name.lowercase() }.thenBy { it.id })
        val listed = projects.mapTo(HashSet()) { it.id }
        mutableState.value = WorkspaceView(
            projects = projects,
            boards = boards,
            retiredBoards = retired.sortedBy { it.id },
            cards = cards.sortedBy { it.id }.groupBy { it.project_id },
            chats = chats.sortedWith(compareByDescending<Card> { DirectoryReducer.activityTime(it) }.thenBy { it.id }),
            projectReplicas = administered.projectReplicas.filterKeys { it in listed },
            settings = settings,
            conversations = conversations,
            pendingCardIds = pendingIds,
            loaded = loaded,
        )
    }

    /**
     * [directory] with the pending administrative results applied: projects
     * and their replicas, checkouts, and boards. A pending board's lifecycle
     * joins the known one (the newer description wins), a board a card in
     * [items] still references cannot retire, and each board lists as live or
     * retired accordingly.
     */
    private fun withAdministration(items: Collection<Card>): DirectoryProjection {
        if (pendingProjects.isEmpty() && pendingReplicas.isEmpty() && pendingCheckouts.isEmpty() && pendingBoards.isEmpty()) return directory
        val projects = LinkedHashMap(directory.projects)
        for ((id, project) in pendingProjects) {
            if (project.archived) projects.remove(id) else projects[id] = DirectoryReducer.mergeProject(projects[id], project)
        }
        for (checkout in pendingCheckouts.values) {
            val project = projects[checkout.project_id] ?: continue
            projects[project.id] = DirectoryReducer.mergeProject(project, project.copy(checkouts = listOf(checkout)))
        }
        val all = LinkedHashMap(directory.retiredBoards)
        for (list in directory.boards.values) for (board in list) all[board.id] = board
        if (pendingBoards.isNotEmpty()) {
            val referenced = DirectoryReducer.referencedBoards(items)
            for ((id, pending) in pendingBoards) {
                val known = all[id]
                val joined = if (known != null && Timestamps.compare(known.updated_at, pending.updated_at) > 0) {
                    DirectoryReducer.mergeBoardLifecycle(known, pending)
                } else {
                    DirectoryReducer.mergeBoardLifecycle(pending, known)
                }
                all[id] = DirectoryReducer.blockingReferenced(joined, referenced)
            }
        }
        val boards = HashMap<String, MutableList<Board>>()
        val retired = HashMap<String, Board>()
        for (board in all.values) {
            if (!projects.containsKey(board.project_id)) continue
            if (board.retired) retired[board.id] = board else boards.getOrPut(board.project_id) { mutableListOf() }.add(board)
        }
        return directory.copy(
            projects = projects,
            projectReplicas = if (pendingReplicas.isEmpty()) directory.projectReplicas else pendingReplicas + directory.projectReplicas,
            boards = boards.mapValues { (_, list) -> list.sortedBy { it.id } },
            retiredBoards = retired,
        )
    }

    /** The project [projectId] was consolidated into, following chains; itself when none. */
    private fun destinationOf(projectId: String): String {
        var id = projectId
        repeat(pendingConsolidations.size) { id = pendingConsolidations[id] ?: return id }
        return id
    }

    private companion object {
        /** A confirmed change the feed never echoes (e.g. a no-op) stops overriding after this. */
        val CONFIRMED_GRACE = 10.seconds
    }
}
