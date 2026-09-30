package com.dbpprt.dieter.ui

import com.dbpprt.dieter.api.v1.Project
import org.junit.Assert.assertEquals
import org.junit.Test

class ProjectOverviewTest {
    @Test fun pinnedProjectsFollowPortableOrderAndIgnoreUnavailableIds() {
        val projects = listOf(project("alpha", "Alpha"), project("beta", "Beta"), project("gamma", "Gamma"))

        assertEquals(
            listOf("gamma", "alpha"),
            orderedPinnedProjects(projects, listOf("gamma", "missing", "alpha", "gamma")).map { it.id },
        )
    }

    @Test fun pinnedProjectsStayEmptyWithoutSynchronizedMembership() {
        val projects = listOf(project("alpha", "Alpha"), project("beta", "Beta"))
        assertEquals(emptyList<Project>(), orderedPinnedProjects(projects, emptyList()))
    }

    private fun project(id: String, name: String) = Project(id = id, name = name)
}
