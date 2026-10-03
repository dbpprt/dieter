package com.dbpprt.dieter.core.navigation

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.core.search.ListFilters

/** The chats list: pinned chats, folders, one section per project, and chats of projects no longer listed. */
data class ChatSections(
    /** Visible pinned chats in the shared pinned order. */
    val pinned: List<Card>,
    /** Folders holding a matching chat, or named like the query. */
    val folders: List<NavigationFolder>,
    /** Every matching chat, newest activity first, for looking up folder items. */
    val chats: Map<String, Card>,
    /** Projects with a section, each with its unpinned, unfiled chats. */
    val projects: List<Project>,
    val projectChats: Map<String, List<Card>>,
    /** Unpinned, unfiled chats whose project is not listed. */
    val other: List<Card>,
)

/** One chat folder as the chats list shows it. */
data class ChatFolderGroup(
    val id: String,
    val name: String,
    /** Its shown chats, in the folder's order. */
    val chatIds: List<String>,
    /** The folder's saved disclosure; a toggle flips it. */
    val expanded: Boolean,
    /** Its chats show: the folder is expanded, or a search runs. */
    val showChats: Boolean,
)

/** One project's section as the chats list shows it. */
data class ChatProjectGroup(
    val projectId: String,
    /** The chats to show, newest activity first: all of them while showing all or searching, else the preview. */
    val chatIds: List<String>,
    /** Every chat of the section. */
    val total: Int,
    /** Chats beyond the preview, behind "Show N more" (or "Show fewer" while showing all); none while searching. */
    val hidden: Int,
    /** The section's saved collapse; a toggle flips it. */
    val collapsed: Boolean,
    /** The project shows all its chats instead of the preview. */
    val showAll: Boolean,
    /** Its chats show: the section is not collapsed, or a search runs. */
    val showChats: Boolean,
)

/** The chats list as every client shows it, by chat ID. */
data class ChatList(
    /** Pinned chats in the shared pinned order; none while archived chats show. */
    val pinned: List<String> = emptyList(),
    val folders: List<ChatFolderGroup> = emptyList(),
    /** Project sections in the shared project order. */
    val projects: List<ChatProjectGroup> = emptyList(),
    /** Unpinned, unfiled chats whose project is not listed. */
    val other: List<String> = emptyList(),
    /** Every shown chat, newest activity first. */
    val visible: List<String> = emptyList(),
)

object ChatLists {
    /** Newest activity first (the last update when a chat has none), then by ID. */
    private val NEWEST_FIRST = compareByDescending<Card> { it.last_activity_at.ifEmpty { it.updated_at } }.thenBy { it.id }

    /**
     * Groups [chats] for the list. The query matches titles, summaries,
     * projects, and folders; with folders present, a project gets a section
     * only for chats outside them. [archived] chats show no pinned section:
     * pinned ones stay in their project's section.
     */
    fun sections(
        chats: List<Card>,
        projects: List<Project>,
        folders: List<NavigationFolder>,
        pinnedOrder: List<String>,
        query: String,
        archived: Boolean = false,
    ): ChatSections {
        val term = query.trim()
        val matching = ListFilters.chats(chats, projects, folders, term).sortedWith(NEWEST_FIRST)
        val byId = matching.associateBy { it.id }
        val pinned = if (archived) emptyList() else pinnedOrder.mapNotNull { id -> byId[id]?.takeIf { it.pinned } }
        val filed = folders.flatMapTo(HashSet()) { it.itemIds }
        val grouped = matching.filterNot { it.id in filed || (!archived && it.pinned) }
        val byProject = grouped.groupBy { it.project_id }
        val listed = ListFilters.chatProjects(projects, grouped, term).filter { folders.isEmpty() || byProject[it.id].orEmpty().isNotEmpty() }
        val known = projects.mapTo(HashSet()) { it.id }
        return ChatSections(
            pinned = pinned,
            folders = folders.filter { folder -> term.isEmpty() || folder.name.contains(term, ignoreCase = true) || folder.itemIds.any(byId::containsKey) },
            chats = byId,
            projects = listed,
            projectChats = byProject,
            other = grouped.filter { it.project_id !in known },
        )
    }

    /** The list as shown under the navigation [layout] ([present]). */
    fun present(chats: List<Card>, projects: List<Project>, layout: NavigationLayout, query: String, archived: Boolean = false): ChatList =
        present(chats, projects, layout.chatLayout(), query, archived)

    /**
     * The list as shown: [projects] that are not archived, in the shared
     * order; chat folders, the pinned order, and each section's collapse and
     * "show all" from [layout]. A search shows every match, collapsed
     * sections and folders included.
     */
    fun present(chats: List<Card>, projects: List<Project>, layout: ChatLayout, query: String, archived: Boolean = false): ChatList {
        val available = projects.filterNot { it.archived }
        val byId = available.associateBy { it.id }
        val listed = NavigationLayout.inOrder(available.map { it.id }, layout.projectOrder).mapNotNull(byId::get)
        val pinnedOrder = if (archived) emptyList() else NavigationLayout.pinnedChats(chats, layout.pinnedOrder).map { it.id }
        val sections = sections(chats, listed, layout.folders, pinnedOrder, query, archived)
        val searching = query.isNotBlank()
        return ChatList(
            pinned = sections.pinned.map { it.id },
            folders = sections.folders.map { folder ->
                ChatFolderGroup(folder.id, folder.name, folder.itemIds.filter(sections.chats::containsKey), folder.expanded, folder.expanded || searching)
            },
            projects = sections.projects.map { project ->
                val all = sections.projectChats[project.id].orEmpty()
                val showAll = project.id in layout.showAll
                val collapsed = project.id in layout.collapsed
                ChatProjectGroup(
                    projectId = project.id, chatIds = visible(all, showAll, query).map { it.id }, total = all.size, hidden = hidden(all, query),
                    collapsed = collapsed, showAll = showAll, showChats = !collapsed || searching,
                )
            },
            other = sections.other.map { it.id },
            visible = sections.chats.keys.toList(),
        )
    }

    /** A project's section shows a preview unless expanded or searching. */
    fun visible(projectChats: List<Card>, expanded: Boolean, query: String): List<Card> =
        if (expanded || query.isNotBlank()) projectChats else projectChats.take(NavigationLayout.PROJECT_CHAT_PREVIEW)

    /** Chats hidden behind "Show more", when a preview applies. */
    fun hidden(projectChats: List<Card>, query: String): Int =
        if (query.isNotBlank()) 0 else (projectChats.size - NavigationLayout.PROJECT_CHAT_PREVIEW).coerceAtLeast(0)

    /** "Show 3 more", or "Show fewer" while [showAll]; empty when nothing is [hidden]. */
    fun toggleLabel(hidden: Int, showAll: Boolean): String = when {
        hidden <= 0 -> ""
        showAll -> "Show fewer"
        else -> "Show $hidden more"
    }
}
