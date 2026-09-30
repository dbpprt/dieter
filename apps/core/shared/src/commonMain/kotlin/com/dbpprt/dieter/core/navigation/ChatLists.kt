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
    /** Every matching chat, for looking up folder items. */
    val chats: Map<String, Card>,
    /** Projects with a section, each with its unpinned, unfiled chats. */
    val projects: List<Project>,
    val projectChats: Map<String, List<Card>>,
    /** Unpinned, unfiled chats whose project is not listed. */
    val other: List<Card>,
)

object ChatLists {
    /**
     * Groups [chats] for the list. The query matches titles, projects, and
     * folders; with folders present, a project gets a section only for chats
     * outside them.
     */
    fun sections(chats: List<Card>, projects: List<Project>, folders: List<NavigationFolder>, pinnedOrder: List<String>, query: String): ChatSections {
        val term = query.trim()
        val matching = ListFilters.chats(chats, projects, folders, term)
            .sortedWith(compareByDescending<Card> { it.pinned }.thenByDescending { it.last_activity_at })
        val byId = matching.associateBy { it.id }
        val pinned = pinnedOrder.mapNotNull { id -> byId[id]?.takeIf { it.pinned } }
        val filed = folders.flatMapTo(HashSet()) { it.itemIds }
        val unfiled = matching.filterNot { it.id in filed }
        val byProject = unfiled.filterNot { it.pinned }.groupBy { it.project_id }
        val listed = ListFilters.chatProjects(projects, unfiled, term).filter { folders.isEmpty() || byProject[it.id].orEmpty().isNotEmpty() }
        val known = projects.mapTo(HashSet()) { it.id }
        return ChatSections(
            pinned = pinned,
            folders = folders.filter { folder -> term.isEmpty() || folder.name.contains(term, ignoreCase = true) || folder.itemIds.any(byId::containsKey) },
            chats = byId,
            projects = listed,
            projectChats = byProject,
            other = unfiled.filter { !it.pinned && it.project_id !in known },
        )
    }

    /** A project's section shows a preview unless expanded or searching. */
    fun visible(projectChats: List<Card>, expanded: Boolean, query: String): List<Card> =
        if (expanded || query.isNotBlank()) projectChats else projectChats.take(NavigationLayout.PROJECT_CHAT_PREVIEW)

    /** Chats hidden behind "Show more", when a preview applies. */
    fun hidden(projectChats: List<Card>, query: String): Int =
        if (query.isNotBlank()) 0 else (projectChats.size - NavigationLayout.PROJECT_CHAT_PREVIEW).coerceAtLeast(0)
}
