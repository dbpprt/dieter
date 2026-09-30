package com.dbpprt.dieter.core.navigation

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.core.search.ListFilters
import kotlin.test.Test
import kotlin.test.assertEquals

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
}
