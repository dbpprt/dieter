package com.dbpprt.dieter.core.navigation

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.core.search.ListFilters
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import okio.ByteString.Companion.encodeUtf8

class ChatListsTest {
    private val emptyProject = Project(id = "project-empty", name = "Empty project")
    private val activeProject = Project(id = "project-active", name = "Active project")
    private val activeChat = Card(id = "chat-active", project_id = activeProject.id, title = "Existing chat", last_activity_at = "2026-08-14T10:00:00Z")

    @Test fun listIncludesProjectsWithoutChatsUntilASearchNarrowsIt() {
        val all = ChatLists.sections(listOf(activeChat), listOf(emptyProject, activeProject), emptyList(), emptyList(), "")
        assertEquals(listOf(emptyProject.id, activeProject.id), all.projects.map { it.id })
        assertEquals(listOf(activeChat), all.projectChats[activeProject.id])
        val searched = ChatLists.sections(listOf(activeChat), listOf(emptyProject, activeProject), emptyList(), emptyList(), "Existing")
        assertEquals(listOf(activeProject.id), searched.projects.map { it.id })
        assertEquals(listOf(emptyProject.id), ListFilters.chatProjects(listOf(emptyProject, activeProject), emptyList(), "empty").map { it.id })
    }

    @Test fun newChatSelectorOffersEveryProjectByName() {
        assertEquals(listOf(activeProject.id to "Active project", emptyProject.id to "Empty project"), ListFilters.projectOptions(listOf(emptyProject, activeProject)))
    }

    @Test fun searchMatchesProjectAndFolderNamesAsWellAsTitles() {
        val other = activeChat.copy(id = "chat-other", project_id = emptyProject.id, title = "Release notes")
        val folders = listOf(NavigationFolder("news", "NewsOS", listOf(other.id)))
        val chats = listOf(activeChat, other)
        val projects = listOf(activeProject, emptyProject)
        assertEquals(listOf(activeChat), ListFilters.chats(chats, projects, folders, "  ACTIVE PROJECT  "))
        assertEquals(listOf(other), ListFilters.chats(chats, projects, folders, "newsos"))
        assertEquals(listOf(other), ListFilters.chats(chats, projects, folders, "release"))
        assertEquals(emptyList(), ListFilters.chats(chats, projects, folders, "missing"))
        assertEquals(chats, ListFilters.chats(chats, projects, folders, "  "))
    }

    @Test fun foldersPinsAndUnknownProjectsGetTheirOwnPlaces() {
        val pinned = activeChat.copy(id = "pinned", pinned = true)
        val filed = activeChat.copy(id = "filed")
        val orphan = activeChat.copy(id = "orphan", project_id = "gone")
        val folders = listOf(NavigationFolder("f", "Research", listOf("filed")))
        val sections = ChatLists.sections(listOf(activeChat, pinned, filed, orphan), listOf(activeProject, emptyProject), folders, listOf("pinned", "missing"), "")
        assertEquals(listOf("pinned"), sections.pinned.map { it.id })
        assertEquals(listOf("f"), sections.folders.map { it.id })
        // With folders present, a project gets a section only for chats outside them.
        assertEquals(listOf(activeProject.id), sections.projects.map { it.id })
        assertEquals(listOf("chat-active"), sections.projectChats[activeProject.id]?.map { it.id })
        assertEquals(listOf("orphan"), sections.other.map { it.id })
        assertEquals(listOf("f"), ChatLists.sections(listOf(filed), listOf(activeProject), folders, emptyList(), "resear").folders.map { it.id })
    }

    @Test fun projectSectionsPreviewUntilExpandedOrSearching() {
        val chats = (1..(NavigationLayout.PROJECT_CHAT_PREVIEW + 3)).map { Card(id = "c$it") }
        assertEquals(NavigationLayout.PROJECT_CHAT_PREVIEW, ChatLists.visible(chats, expanded = false, query = "").size)
        assertEquals(chats, ChatLists.visible(chats, expanded = true, query = ""))
        assertEquals(chats, ChatLists.visible(chats, expanded = false, query = "c"))
        assertEquals(3, ChatLists.hidden(chats, ""))
        assertEquals(0, ChatLists.hidden(chats, "c"))
        assertEquals(0, ChatLists.hidden(chats.take(1), ""))
    }

    @Test fun searchAlsoMatchesSummaries() {
        val summarized = activeChat.copy(id = "summarized", title = "Untitled", summary = "Refactors the gateway")
        assertEquals(listOf(summarized), ListFilters.chats(listOf(activeChat, summarized), emptyList(), emptyList(), "GATEWAY"))
    }

    @Test fun chatsSortByLatestActivityElseLastUpdateThenId() {
        val older = Card(id = "a", project_id = activeProject.id, last_activity_at = "2026-08-01T00:00:00Z")
        val updated = Card(id = "b", project_id = activeProject.id, updated_at = "2026-08-02T00:00:00Z")
        val tie = Card(id = "c", project_id = activeProject.id, last_activity_at = "2026-08-01T00:00:00Z")
        val sections = ChatLists.sections(listOf(tie, older, updated), listOf(activeProject), emptyList(), emptyList(), "")
        assertEquals(listOf("b", "a", "c"), sections.projectChats[activeProject.id]?.map { it.id })
    }

    @Test fun aPinnedMatchShowsOnlyInThePinnedSection() {
        val pinned = activeChat.copy(id = "pin", project_id = emptyProject.id, title = "Pinned topic", pinned = true)
        val sections = ChatLists.sections(listOf(activeChat, pinned), listOf(activeProject, emptyProject), emptyList(), listOf("pin"), "topic")
        assertEquals(listOf("pin"), sections.pinned.map { it.id })
        assertEquals(emptyList(), sections.projects, "no project section for a pinned chat alone")
    }

    /** Ported from the Mac's `chatListProjectionIndexesProjectsInOnePass`. */
    @Test fun theListPinsChatsAndGroupsTheRestByProject() {
        fun chat(id: String, project: String, pinned: Boolean = false) = Card(id = id, project_id = project, scope = "chat", title = id, pinned = pinned, updated_at = id)
        val pinned = chat("pinned", "alpha", pinned = true)
        val alpha = chat("alpha", "alpha")
        val beta = chat("beta", "beta")
        val projects = listOf(Project(id = "alpha", name = "Alpha"), Project(id = "beta", name = "Beta"), Project(id = "gone", name = "Gone", archived = true))
        val list = ChatLists.present(listOf(alpha, beta, pinned), projects, NavigationLayout(emptyMap()), "")
        assertEquals(3, list.visible.size)
        assertEquals(listOf("pinned"), list.pinned)
        assertEquals(listOf("alpha", "beta"), list.projects.map { it.projectId }, "archived projects get no section")
        assertEquals(listOf("alpha"), list.projects[0].chatIds)
        assertEquals(listOf("beta"), list.projects[1].chatIds)
    }

    @Test fun archivedChatsKeepPinsInTheirProjectAndChatsOfUnlistedProjectsAreOther() {
        val pinned = activeChat.copy(id = "pinned", pinned = true, archived = true)
        val orphan = activeChat.copy(id = "orphan", project_id = "archived-project", archived = true)
        val projects = listOf(activeProject, Project(id = "archived-project", name = "Old", archived = true))
        val list = ChatLists.present(listOf(pinned, orphan), projects, NavigationLayout(emptyMap()), "", archived = true)
        assertEquals(emptyList(), list.pinned)
        assertEquals(listOf("pinned"), list.projects.single().chatIds)
        assertEquals(listOf("orphan"), list.other)
        assertEquals(listOf("orphan", "pinned"), list.visible)
    }

    @Test fun sectionsFollowTheirSavedDisclosureUntilASearchShowsEveryMatch() {
        val many = (1..7).map { Card(id = "c$it", project_id = activeProject.id, title = "Chat $it", last_activity_at = "2026-08-0${it}T00:00:00Z") }
        val filed = Card(id = "filed", project_id = emptyProject.id, title = "Filed")
        val saved = mapOf(
            "chats-section.${activeProject.id}.expanded" to "false".encodeUtf8(),
            "chats-folder.f.name" to "\"Research\"".encodeUtf8(),
            "chats-folder.f.expanded" to "false".encodeUtf8(),
            "chats-item.filed.position" to SharedKv.encodePosition(KvPosition("f", "a")),
        )
        val projects = listOf(activeProject, emptyProject)
        val shown = ChatLists.present(many + filed, projects, NavigationLayout(saved), "")
        val section = shown.projects.single()
        assertEquals(listOf("c7", "c6", "c5", "c4", "c3"), section.chatIds)
        assertEquals(7, section.total)
        assertEquals(2, section.hidden)
        assertTrue(section.collapsed)
        assertFalse(section.showChats)
        assertFalse(section.showAll)
        val folder = shown.folders.single()
        assertEquals(ChatFolderGroup("f", "Research", listOf("filed"), expanded = false, showChats = false), folder)

        val all = ChatLists.present(many + filed, projects, NavigationLayout(saved + ("chats-disclosure.${activeProject.id}.expanded" to "true".encodeUtf8())), "")
        assertEquals(7, all.projects.single().chatIds.size)
        assertEquals(2, all.projects.single().hidden, "\"Show fewer\" while showing all")

        val searched = ChatLists.present(many + filed, projects, NavigationLayout(saved), "chat")
        assertEquals(7, searched.projects.single().chatIds.size)
        assertEquals(0, searched.projects.single().hidden)
        assertTrue(searched.projects.single().collapsed && searched.projects.single().showChats, "a search opens a collapsed section")
        assertEquals(emptyList(), searched.folders)
        val folderSearch = ChatLists.present(many + filed, projects, NavigationLayout(saved), "filed").folders.single()
        assertTrue(!folderSearch.expanded && folderSearch.showChats, "a search opens a collapsed folder")
    }

    @Test
    fun theShowMoreButtonNamesWhatItReveals() {
        assertEquals("", ChatLists.toggleLabel(hidden = 0, showAll = false))
        assertEquals("Show 3 more", ChatLists.toggleLabel(hidden = 3, showAll = false))
        assertEquals("Show fewer", ChatLists.toggleLabel(hidden = 3, showAll = true))
    }
}
