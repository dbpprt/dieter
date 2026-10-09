package com.dbpprt.dieter.core.store

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Checkout
import com.dbpprt.dieter.api.v1.Conversation
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.core.board.Cards
import com.dbpprt.dieter.core.runtime.Timestamps
import com.dbpprt.dieter.core.sync.AccountProjector
import com.dbpprt.dieter.core.sync.DirectoryProjection
import com.dbpprt.dieter.core.sync.Registers
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
    /** Card ID → the latest turn its owner reports (active and recently active conversations). */
    val activities: Map<String, Conversation> = emptyMap(),
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

/**
 * A card that exists only locally. [aliases] are the IDs its synced copy may
 * appear under (the daemon's deterministic or acknowledged ID); once any of
 * them is listed, the synced copy replaces it, so the card never shows twice.
 */
data class PendingItem(val card: Card, val daemonId: String, val aliases: Set<String> = emptySet())

/**
 * The single reducer for workspace state. The account view from the
 * machines' streams, administrative results, and optimistic overlays all
 * enter here; views never keep their own copies. Confined to the core
 * dispatcher.
 */
class WorkspaceStore(private val clock: Clock = Clock.System) {
    private var directory = DirectoryProjection.EMPTY

    /** [directory] with the administrative results no machine's view shows yet. */
    private var administered = DirectoryProjection.EMPTY
    private val overlays = LinkedHashMap<String, CardOverlay>()
    private val confirmedAt = HashMap<String, Instant>()

    /** Overlays whose item the account view has listed; one that leaves it again is done. */
    private val shown = HashSet<String>()
    private val pendingItems = LinkedHashMap<String, PendingItem>()
    private val pendingProjects = LinkedHashMap<String, Project>()

    /** Checkout ID → an attached, detached, or consolidated checkout. */
    private val pendingCheckouts = LinkedHashMap<String, Checkout>()

    /** Consolidated project ID → the project it was folded into. */
    private val pendingConsolidations = LinkedHashMap<String, String>()
    private val pendingBoards = LinkedHashMap<String, Board>()
    private var loaded = false
    private val mutableState = MutableStateFlow(WorkspaceView())
    val state: StateFlow<WorkspaceView> = mutableState.asStateFlow()

    private val mutableOverlayIds = MutableStateFlow<Set<String>>(emptySet())

    /** Optimistic changes the account view does not show yet. */
    val overlayIds: StateFlow<Set<String>> = mutableOverlayIds.asStateFlow()

    private val mutableRevision = MutableStateFlow(0L)

    /** Advances whenever the account view changes. */
    val revision: StateFlow<Long> = mutableRevision.asStateFlow()

    /**
     * The merged directory, with the projects, checkouts, and boards
     * administrative calls returned that no machine's view shows yet, so a
     * call that follows one reaches the right machine. Cards are the
     * directory's.
     */
    val directoryProjection: DirectoryProjection get() = administered

    /**
     * [id]'s synced item as this client shows it: the account view's copy
     * with the changes still in flight applied, so a change builds on the
     * one before it.
     */
    fun shownItem(id: String): Card? = directory.item(id)?.let { item ->
        overlays.values.fold(item) { card, overlay -> if (overlay.cardId == id) overlay.apply(card) else card }
    }

    /** The account view the machines' streams add up to; [loaded] once any machine's view was applied. */
    fun applyDirectory(next: DirectoryProjection, loaded: Boolean) {
        if (next == directory && loaded == this.loaded) return
        directory = next
        this.loaded = loaded
        reconcile()
        mutableRevision.value++
        publish()
    }

    fun addOverlay(overlay: CardOverlay) {
        overlays[overlay.operationId] = overlay
        reconcile()
        publish()
    }

    /** The mutation reached the daemon; keep the overlay until the account view catches up. */
    fun confirmOverlay(operationId: String) {
        if (overlays.containsKey(operationId)) confirmedAt[operationId] = clock.now()
        reconcile()
        publish()
    }

    /** The mutation failed: restore the directory's value. */
    fun rollbackOverlay(operationId: String) {
        confirmedAt.remove(operationId)
        shown.remove(operationId)
        if (overlays.remove(operationId) != null) publish()
    }

    /**
     * Shows a project an administrative call returned until the account view
     * is at least as new; another peer's later edit is never pinned. Its
     * checkouts route the calls that follow.
     */
    fun overlayProject(project: Project) {
        pendingProjects[project.id] = project
        reconcile()
        publish()
    }

    /** A board as the client currently knows it: a pending response, the directory, or the retired list. */
    fun findBoard(id: String): Board? = pendingBoards[id] ?: directory.board(id) ?: directory.retiredBoards[id]

    /**
     * Shows a board an administrative call returned, as its machine projected
     * it, until the account view is at least as new and includes its
     * retirement intent.
     */
    fun overlayBoard(board: Board) {
        pendingBoards[board.id] = board
        reconcile()
        publish()
    }

    /** Shows an attached or detached checkout on its project until the account view lists it so. */
    fun overlayCheckout(checkout: Checkout) {
        pendingCheckouts[checkout.id] = checkout
        reconcile()
        publish()
    }

    /**
     * [sourceId] was folded into [destination]: the source leaves the
     * workspace, its boards and items show on the destination, and the
     * destination shows the checkouts the call returned, until the account
     * view no longer lists the source.
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

    /** Drops every overlay and pending result, e.g. when the account changes; the account view stays. */
    fun clear() {
        overlays.clear()
        confirmedAt.clear()
        shown.clear()
        pendingItems.clear()
        pendingProjects.clear()
        pendingCheckouts.clear()
        pendingConsolidations.clear()
        pendingBoards.clear()
        mutableRevision.value++
        publish()
    }

    /**
     * Drops overlays the directory now reflects, whose item left it after it
     * was listed (an archive, or the item is gone), or that were confirmed
     * long enough ago. An item the directory does not list yet, e.g. one
     * still being created, keeps its overlays.
     */
    private fun reconcile() {
        pendingProjects.entries.removeAll { (id, pending) ->
            directory.projects[id]?.let { Timestamps.compare(it.updated_at, pending.updated_at) >= 0 } == true
        }
        pendingCheckouts.values.removeAll { pending ->
            directory.projects[pending.project_id]?.checkouts?.any { it.id == pending.id && (it.detached || !pending.detached) } == true
        }
        pendingConsolidations.keys.removeAll { it !in directory.projects }
        pendingBoards.entries.removeAll { (id, pending) ->
            // Retiring or restoring keeps the board's timestamp; its lifecycle shows the view has the intent.
            val known = directory.board(id) ?: directory.retiredBoards[id]
            known != null && Timestamps.compare(known.updated_at, pending.updated_at) >= 0 &&
                pending.retirement_versions.all { version -> known.retirement_versions.any { Registers.covers(it.clock, version.clock) } }
        }
        val now = clock.now()
        val iterator = overlays.entries.iterator()
        while (iterator.hasNext()) {
            val (id, overlay) = iterator.next()
            val card = directory.item(overlay.cardId)
            if (card != null) shown += id
            val left = card == null && id in shown
            val confirmed = confirmedAt[id]
            if (left || (card != null && overlay.satisfiedBy(card)) || (confirmed != null && now - confirmed > CONFIRMED_GRACE)) {
                iterator.remove()
                confirmedAt.remove(id)
                shown.remove(id)
            }
        }
    }

    private fun publish() {
        mutableOverlayIds.value = overlays.keys.toSet()
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
        administered = withAdministration()
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
        mutableState.value = WorkspaceView(
            projects = projects,
            boards = boards,
            retiredBoards = retired.sortedBy { it.id },
            cards = cards.sortedBy { it.id }.groupBy { it.project_id },
            chats = chats.sortedWith(compareByDescending<Card> { AccountProjector.activityTime(it) }.thenBy { it.id }),
            activities = directory.activities,
            pendingCardIds = pendingIds,
            loaded = loaded,
        )
    }

    /**
     * [directory] with the pending administrative results applied: projects,
     * their checkouts, and boards, each board listing as live or retired as
     * its machine projected it.
     */
    private fun withAdministration(): DirectoryProjection {
        if (pendingProjects.isEmpty() && pendingCheckouts.isEmpty() && pendingBoards.isEmpty()) return directory
        val projects = LinkedHashMap(directory.projects)
        for ((id, project) in pendingProjects) {
            if (project.archived) projects.remove(id) else projects[id] = project.copy(checkouts = withCheckouts(projects[id]?.checkouts.orEmpty(), project.checkouts))
        }
        for (checkout in pendingCheckouts.values) {
            val project = projects[checkout.project_id] ?: continue
            projects[project.id] = project.copy(checkouts = withCheckouts(project.checkouts, listOf(checkout)))
        }
        val all = LinkedHashMap(directory.retiredBoards)
        for (list in directory.boards.values) for (board in list) all[board.id] = board
        all.putAll(pendingBoards)
        val boards = HashMap<String, MutableList<Board>>()
        val retired = HashMap<String, Board>()
        for (board in all.values) {
            if (!projects.containsKey(board.project_id)) continue
            if (board.retired) retired[board.id] = board else boards.getOrPut(board.project_id) { mutableListOf() }.add(board)
        }
        return directory.copy(
            projects = projects,
            boards = boards.mapValues { (_, list) -> list.sortedBy { it.id } },
            retiredBoards = retired,
        )
    }

    /** [known] checkouts with [incoming] ones applied; a detached checkout stays detached, and known paths stay. */
    private fun withCheckouts(known: List<Checkout>, incoming: List<Checkout>): List<Checkout> {
        val checkouts = LinkedHashMap<String, Checkout>()
        for (checkout in known) checkouts[checkout.id] = checkout
        for (checkout in incoming) {
            val prior = checkouts[checkout.id]
            if (prior?.detached == true && !checkout.detached) continue
            checkouts[checkout.id] = if (checkout.path.isEmpty() && prior != null) {
                checkout.copy(path = prior.path, validation_commands = prior.validation_commands)
            } else {
                checkout
            }
        }
        return checkouts.values.sortedBy { it.id }
    }

    /** The project [projectId] was consolidated into, following chains; itself when none. */
    private fun destinationOf(projectId: String): String {
        var id = projectId
        repeat(pendingConsolidations.size) { id = pendingConsolidations[id] ?: return id }
        return id
    }

    private companion object {
        /** A confirmed change the account view never shows (e.g. a no-op) stops overriding after this. */
        val CONFIRMED_GRACE = 10.seconds
    }
}
