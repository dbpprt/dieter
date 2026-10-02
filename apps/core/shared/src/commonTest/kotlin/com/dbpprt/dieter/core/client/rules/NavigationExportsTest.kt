package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.client.v1.Cards
import com.dbpprt.dieter.client.v1.NavigationFolder
import com.dbpprt.dieter.client.v1.NavigationSlice
import com.dbpprt.dieter.client.v1.Projects
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class NavigationExportsTest {
    @Test
    fun folderNamesAreBoundedAndUniqueIgnoringCaseAndAccents() {
        assertEquals("", NavigationExports.folderNameProblem(" Work ", listOf("Home")))
        assertEquals("A folder with this name already exists.", NavigationExports.folderNameProblem(" café ", listOf("Home", "CAFE")))
        assertEquals("Folder names must be 1 to 256 bytes.", NavigationExports.folderNameProblem("   ", emptyList()))
        assertEquals("Folder names must be 1 to 256 bytes.", NavigationExports.folderNameProblem("界".repeat(86), emptyList()))
        assertEquals("", NavigationExports.folderNameProblem("界".repeat(85), emptyList()))
        // Renaming a folder passes the other folders' names only.
        assertEquals("", NavigationExports.folderNameProblem("Work", listOf("Home")))
    }

    private val projects = Projects(listOf(Project(id = "a", name = "Alpha"), Project(id = "b", name = "Beta"), Project(id = "c", name = "Gamma"), Project(id = "x", archived = true)))

    @Test
    fun theSidebarLaysGivenProjectsOutUnderTheSavedLayout() {
        val navigation = NavigationSlice(
            project_order = listOf("c", "gone", "a"), pinned_projects = listOf("b", "gone"), expanded_projects = listOf("a", "x"),
            project_folders = listOf(NavigationFolder(id = "f", name = "Work", item_ids = listOf("a", "gone"))),
        )
        val sidebar = NavigationExports.sidebarProjects(navigation, projects)
        assertEquals(listOf("c", "a", "b"), sidebar.order, "the saved order first, the rest in their given order; archived projects are left out")
        assertEquals(listOf("a"), sidebar.folders.single().item_ids)
        assertEquals(listOf("c", "b"), sidebar.unfiled)
        assertEquals(listOf("b"), sidebar.pinned)
        assertEquals(listOf("a"), sidebar.expanded)
    }

    @Test
    fun theChatsListLaysGivenChatsOutUnderTheSavedLayout() {
        fun chat(id: String, project: String, at: String, pinned: Boolean = false, archived: Boolean = false) =
            Card(id = id, scope = "chat", project_id = project, title = "Chat $id", last_activity_at = at, pinned = pinned, archived = archived)
        val chats = Cards(
            listOf(
                chat("old", "a", "2026-09-01T00:00:00Z"), chat("new", "a", "2026-09-02T00:00:00Z"), chat("pin", "b", "2026-09-03T00:00:00Z", pinned = true),
                chat("filed", "c", "2026-09-04T00:00:00Z"), chat("gone", "a", "2026-09-05T00:00:00Z", archived = true),
            ),
        )
        val navigation = NavigationSlice(
            project_order = listOf("b", "a", "c"), chat_folders = listOf(NavigationFolder(id = "f", name = "Research", item_ids = listOf("filed"), expanded = false)),
            collapsed_chat_sections = listOf("a"),
        )
        val live = NavigationExports.chatList(chats, projects, navigation, query = "", archived = false)
        assertEquals(listOf("pin"), live.pinned_ids)
        assertEquals(listOf("filed"), live.folders.single().chat_ids)
        assertTrue(!live.folders.single().show_chats, "a collapsed folder hides its chats")
        assertEquals(listOf("a"), live.projects.map { it.project_id }, "with folders, only projects with chats outside them")
        assertEquals(listOf("new", "old"), live.projects.single().chat_ids)
        assertTrue(live.projects.single().collapsed && !live.projects.single().show_chats)
        assertEquals(listOf("filed", "pin", "new", "old"), live.visible_ids, "newest activity first")
        assertTrue(live.archived.isEmpty())
        val searched = NavigationExports.chatList(chats, projects, navigation, query = "chat new", archived = false)
        assertEquals(listOf("new"), searched.visible_ids)
        assertTrue(searched.projects.single().show_chats, "a search shows collapsed sections")
        val archived = NavigationExports.chatList(chats, projects, navigation, query = "", archived = true)
        assertEquals(listOf("gone"), archived.visible_ids)
        assertEquals(listOf("gone"), archived.archived.map { it.id })
    }
}
