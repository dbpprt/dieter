package com.dbpprt.dieter.core.navigation

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.core.board.Cards
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.store.WorkspaceView
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import okio.ByteString

/** What a chats list shows: chats matching [query], live or [archived] ones. */
data class ChatsTarget(val query: String = "", val archived: Boolean = false)

/** One view's chats list. */
data class ChatsView(
    val target: ChatsTarget = ChatsTarget(),
    val list: ChatList = ChatList(),
    /** The archived chats shown, newest activity first; live chats are the workspace's. */
    val archivedChats: List<Card> = emptyList(),
    /** Archived chats are loading. */
    val loading: Boolean = false,
    /** Why archived chats could not be read. */
    val error: String? = null,
)

private data class ArchivedChats(val chats: List<Card> = emptyList(), val loading: Boolean = false, val error: String? = null)

/**
 * One view's chats list: the query and mode it binds, the list as shown
 * ([ChatLists.present]), and archived chats, which the workspace leaves out
 * and which load again each time the view switches to them. Confined to the
 * core dispatcher.
 */
class ChatsSurface(
    private val workspace: StateFlow<WorkspaceView>,
    private val navigation: StateFlow<Map<String, ByteString>>,
    private val scope: CoroutineScope,
    private val loadArchived: suspend () -> List<Card>,
) {
    private val target = MutableStateFlow(ChatsTarget())
    private val archive = MutableStateFlow(ArchivedChats())
    private var generation = 0L
    private var load: Job? = null

    /** Only live chats and projects shape the list; other workspace changes (e.g. transcripts) do not rebuild it. */
    val view: Flow<ChatsView> = combine(target, workspace.map { it.chats to it.projects }.distinctUntilChanged(), navigation, archive) { bound, (live, projects), values, archived ->
        build(bound, live, projects, values, archived)
    }.distinctUntilChanged()

    /** The list as shown now. */
    fun current(): ChatsView = workspace.value.let { build(target.value, it.chats, it.projects, navigation.value, archive.value) }

    /** Shows chats whose title, summary, project, or folder contains [query]. */
    fun search(query: String) {
        target.update { it.copy(query = query) }
    }

    /** Shows archived chats, loading them, or live ones. */
    fun showArchived(archived: Boolean) {
        if (target.value.archived == archived) return
        target.update { it.copy(archived = archived) }
        if (archived) reload() else clear()
    }

    /** Loads the archived chats again while they show. */
    fun reload() {
        if (!target.value.archived) return
        load?.cancel()
        val request = ++generation
        archive.update { it.copy(loading = true, error = null) }
        load = scope.launch {
            try {
                val chats = loadArchived().filter { Cards.isChat(it) && it.archived }.distinctBy { it.id }
                if (request == generation) archive.value = ArchivedChats(chats)
            } catch (error: Throwable) {
                if (error is CancellationException) throw error
                if (request == generation) archive.update { it.copy(loading = false, error = Failures.message(error)) }
            }
        }
    }

    /** The account changed: archived chats of the previous one go, and load again while shown. */
    fun reset() {
        clear()
        reload()
    }

    /** Ends the view's work. */
    fun stop() {
        clear()
    }

    private fun clear() {
        generation++
        load?.cancel()
        load = null
        archive.value = ArchivedChats()
    }

    private fun build(target: ChatsTarget, live: List<Card>, projects: List<Project>, values: Map<String, ByteString>, archive: ArchivedChats): ChatsView {
        val layout = NavigationLayout(values)
        if (!target.archived) return ChatsView(target, ChatLists.present(live, projects, layout, target.query))
        // A chat restored since the load is live again.
        val liveIds = live.mapTo(HashSet()) { it.id }
        val archived = archive.chats.filterNot { it.id in liveIds }
        val list = ChatLists.present(archived, projects, layout, target.query, archived = true)
        val byId = archived.associateBy { it.id }
        return ChatsView(target, list, list.visible.mapNotNull(byId::get), archive.loading, archive.error)
    }
}
