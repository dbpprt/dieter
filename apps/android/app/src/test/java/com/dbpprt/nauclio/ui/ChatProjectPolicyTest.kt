package com.dbpprt.nauclio.ui

import com.dbpprt.nauclio.connection.ProjectHost
import com.dbpprt.nauclio.v1.Card
import com.dbpprt.nauclio.v1.Project
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
            projectHosts = mapOf(
                emptyProject.id to ProjectHost("endpoint", "daemon", "workstation", true),
            ),
        )

        assertEquals(
            listOf(
                activeProject.id to "Active project",
                emptyProject.id to "Empty project · workstation",
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

    private fun project(id: String, name: String): Project = Project.newBuilder()
        .setId(id)
        .setName(name)
        .build()
}
