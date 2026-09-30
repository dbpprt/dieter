package com.dbpprt.dieter.core.store

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.ConversationSnapshot
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.api.v1.Settings
import com.dbpprt.dieter.core.sync.DirectoryProjection
import com.dbpprt.dieter.core.sync.DirectoryReducer
import com.dbpprt.dieter.core.sync.MachineSnapshot
import com.dbpprt.dieter.core.runtime.Timestamps
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
    private var settings: Settings? = null
    private var conversations: Map<String, ConversationSnapshot> = emptyMap()
    private val overlays = LinkedHashMap<String, CardOverlay>()
    private val confirmedAt = HashMap<String, Instant>()
    private val pendingItems = LinkedHashMap<String, PendingItem>()
    private val pendingProjects = LinkedHashMap<String, Project>()
    private val pendingBoards = LinkedHashMap<String, Board>()
    private var loaded = false
    private val mutableState = MutableStateFlow(WorkspaceView())
    val state: StateFlow<WorkspaceView> = mutableState.asStateFlow()

    private val mutableRevision = MutableStateFlow(0L)

    /** Advances whenever server-sourced state (directory or conversation tail) changes. */
    val revision: StateFlow<Long> = mutableRevision.asStateFlow()

    val directoryProjection: DirectoryProjection get() = directory

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
     */
    fun overlayProject(project: Project) {
        pendingProjects[project.id] = project
        reconcile()
        publish()
    }

    /** A board as the client currently knows it: a pending response, the directory, or the retired list. */
    fun findBoard(id: String): Board? = pendingBoards[id] ?: directory.board(id) ?: directory.retiredBoards[id]

    fun overlayBoard(board: Board) {
        pendingBoards[board.id] = board
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
        pendingBoards.entries.removeAll { (id, pending) ->
            directory.board(id)?.let { Timestamps.compare(it.updated_at, pending.updated_at) >= 0 } == true ||
                directory.retiredBoards[id]?.let { Timestamps.compare(it.updated_at, pending.updated_at) >= 0 } == true
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
        // Archived items leave every live view; the Archive view reads them on demand.
        val visible = byId.values.filterNot { it.archived }
        val projectsById = LinkedHashMap(directory.projects)
        for ((id, project) in pendingProjects) {
            if (project.archived) projectsById.remove(id) else projectsById[id] = project.copy(checkouts = project.checkouts.ifEmpty { projectsById[id]?.checkouts.orEmpty() })
        }
        val projects = projectsById.values.sortedWith(compareBy<Project> { it.name.lowercase() }.thenBy { it.id })
        val boards = if (pendingBoards.isEmpty()) directory.boards else {
            val all = directory.boards.values.flatten().associateBy { it.id }.toMutableMap()
            for ((id, board) in pendingBoards) if (board.retired) all.remove(id) else all[id] = board
            all.values.groupBy { it.project_id }.mapValues { (_, list) -> list.sortedBy { it.id } }
        }
        mutableState.value = WorkspaceView(
            projects = projects,
            boards = boards,
            retiredBoards = directory.retiredBoards.values.sortedBy { it.id },
            cards = visible.filter { it.scope != "chat" || it.board_id.isNotEmpty() }
                .sortedBy { it.id }.groupBy { it.project_id },
            chats = visible.filter { it.scope == "chat" && it.board_id.isEmpty() }
                .sortedWith(compareByDescending<Card> { DirectoryReducer.activityTime(it) }.thenBy { it.id }),
            projectReplicas = directory.projectReplicas,
            settings = settings,
            conversations = conversations,
            pendingCardIds = pendingIds,
            loaded = loaded,
        )
    }

    private companion object {
        /** A confirmed change the feed never echoes (e.g. a no-op) stops overriding after this. */
        val CONFIRMED_GRACE = 10.seconds
    }
}
