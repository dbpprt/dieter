package com.getdieter.core.client.rules

import com.getdieter.client.v1.Cards
import com.getdieter.client.v1.ChatsSlice
import com.getdieter.client.v1.NavigationFolder as ClientNavigationFolder
import com.getdieter.client.v1.NavigationSlice
import com.getdieter.client.v1.ProjectNavigation
import com.getdieter.client.v1.Projects
import com.getdieter.core.client.chatsSlice
import com.getdieter.core.navigation.ChatLayout
import com.getdieter.core.navigation.ChatLists
import com.getdieter.core.navigation.ChatsTarget
import com.getdieter.core.navigation.ChatsView
import com.getdieter.core.navigation.NavigationEditor
import com.getdieter.core.navigation.NavigationFolder
import com.getdieter.core.navigation.SidebarProjects

/**
 * Navigation rules a folder name sheet checks while the user types, and the sidebar's and the chats
 * list's layout over given projects and chats, e.g. ones a fixture shows without the workspace.
 */
object NavigationExports {
    /**
     * Why [name] cannot name a folder beside [existingNames] (the scope's other folders), or ""
     * when it can: "Folder names must be 1 to 256 bytes." or "A folder with this name already
     * exists.". Names are trimmed; case and Latin accents are ignored when comparing.
     */
    fun folderNameProblem(name: String, existingNames: List<String>): String =
        NavigationEditor.nameProblem(
                name,
                existingNames.mapIndexed { index, existing ->
                    NavigationFolder(index.toString(), existing, emptyList())
                },
            )
            .orEmpty()

    /**
     * The sidebar's [projects] (archived ones left out) under [navigation]'s saved layout, as
     * `NavigationSlice.projects` lays them out.
     */
    fun sidebarProjects(navigation: NavigationSlice, projects: Projects): ProjectNavigation {
        val sidebar =
            SidebarProjects.of(
                projects.projects.filterNot { it.archived }.map { it.id },
                navigation.project_order,
                navigation.project_folders.map(::folder),
                navigation.pinned_projects,
                navigation.expanded_projects,
            )
        return ProjectNavigation(
            order = sidebar.order,
            folders = sidebar.folders.map(::clientFolder),
            unfiled = sidebar.unfiled,
            pinned = sidebar.pinned,
            expanded = sidebar.expanded,
        )
    }

    /**
     * The chats list over [chats] (live ones, or [archived] ones) and [projects] under
     * [navigation]'s saved layout, matching [query], as SLICE_CHATS lays it out.
     */
    fun chatList(
        chats: Cards,
        projects: Projects,
        navigation: NavigationSlice,
        query: String,
        archived: Boolean,
    ): ChatsSlice {
        val layout =
            ChatLayout(
                projectOrder = navigation.project_order,
                pinnedOrder = navigation.pinned_chat_order,
                folders = navigation.chat_folders.map(::folder),
                showAll = navigation.chats_show_all.toSet(),
                collapsed = navigation.collapsed_chat_sections.toSet(),
            )
        val shown = chats.cards.filter { it.archived == archived }
        val list = ChatLists.present(shown, projects.projects, layout, query, archived)
        val byId = shown.associateBy { it.id }
        return chatsSlice(
            ChatsView(
                ChatsTarget(query, archived),
                list,
                if (archived) list.visible.mapNotNull(byId::get) else emptyList(),
            )
        )
    }

    private fun folder(folder: ClientNavigationFolder) =
        NavigationFolder(folder.id, folder.name, folder.item_ids, folder.expanded)

    private fun clientFolder(folder: NavigationFolder) =
        ClientNavigationFolder(folder.id, folder.name, folder.itemIds, folder.expanded)
}
