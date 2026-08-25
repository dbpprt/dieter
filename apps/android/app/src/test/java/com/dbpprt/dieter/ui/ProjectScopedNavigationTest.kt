package com.dbpprt.dieter.ui

import com.dbpprt.dieter.connection.ProjectHost
import com.dbpprt.dieter.v1.Project
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProjectScopedNavigationTest {
    private val project = Project.newBuilder().setId("project").setName("Project").build()

    @Test
    fun `files and schedules stay muted when every known project host is offline`() {
        val offline = DieterUiState(
            projects = listOf(project),
            projectHosts = mapOf(project.id to ProjectHost("endpoint", "daemon", "machine", false)),
        )
        val online = offline.copy(
            projectHosts = mapOf(project.id to ProjectHost("endpoint", "daemon", "machine", true)),
        )

        assertFalse(projectScopedNavigationEnabled(offline))
        assertTrue(projectScopedNavigationEnabled(online))
    }
}
