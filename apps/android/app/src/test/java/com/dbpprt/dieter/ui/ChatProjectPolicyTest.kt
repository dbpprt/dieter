package com.dbpprt.dieter.ui

import com.dbpprt.dieter.connection.ProjectReplica
import com.dbpprt.dieter.settings.NavigationFolderPreferences
import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.Project
import org.junit.Assert.assertEquals
import org.junit.Test

class ChatProjectPolicyTest {
    private val emptyProject = project("project-empty", "Empty project")
    private val activeProject = project("project-active", "Active project")
    private val activeChat = Card.newBuilder()
        .setId("chat-active")
        .setProjectId(activeProject.id)
        .setTitle("Existing chat")
        .build()

    @Test
    fun `chat list includes projects without chats when no search is active`() {
        val visible = chatProjectsForQuery(
            projects = listOf(emptyProject, activeProject),
            filteredChats = listOf(activeChat),
            query = "",
        )

        assertEquals(listOf(emptyProject.id, activeProject.id), visible.map(Project::getId))
    }

    @Test
    fun `new chat selector includes projects without chats`() {
        val options = chatProjectOptions(
            projects = listOf(activeProject, emptyProject),
            projectReplicas = mapOf(
                emptyProject.id to ProjectReplica("endpoint", "daemon", "workstation", true),
            ),
        )

        assertEquals(
            listOf(
                activeProject.id to "Active project",
                emptyProject.id to "Empty project",
            ),
            options,
        )
    }

    @Test
    fun `chat search keeps projects whose chat title matches`() {
        val visible = chatProjectsForQuery(
            projects = listOf(emptyProject, activeProject),
            filteredChats = listOf(activeChat),
            query = "Existing",
        )

        assertEquals(listOf(activeProject.id), visible.map(Project::getId))
    }

    @Test
    fun `search matches project and folder names as well as titles`() {
        val other = activeChat.toBuilder().setId("chat-other").setProjectId(emptyProject.id).setTitle("Release notes").build()
        val folders = NavigationFolderPreferences().adding("NewsOS", "news").moving(other.id, "news")
        val chats = listOf(activeChat, other)
        val projects = listOf(activeProject, emptyProject)
        assertEquals(listOf(activeChat), chatsForQuery(chats, projects, folders, "  ACTIVE PROJECT  "))
        assertEquals(listOf(other), chatsForQuery(chats, projects, folders, "newsos"))
        assertEquals(listOf(other), chatsForQuery(chats, projects, folders, "release"))
        assertEquals(emptyList<Card>(), chatsForQuery(chats, projects, folders, "missing"))
        assertEquals(chats, chatsForQuery(chats, projects, folders, "  "))
    }

    private fun project(id: String, name: String): Project = Project.newBuilder()
        .setId(id)
        .setName(name)
        .build()
}
