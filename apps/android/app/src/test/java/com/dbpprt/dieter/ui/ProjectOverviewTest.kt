package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.Project
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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

    @Test fun projectSortSupportsManualAttentionAndName() {
        val projects = listOf(project("zulu", "Zulu"), project("alpha", "Alpha"), project("beta", "Beta"))
        val cards = mapOf("beta" to listOf(card("review")))

        assertEquals(listOf("zulu", "alpha", "beta"), sortProjects(projects, ProjectOverviewSort.MANUAL, cards).map { it.id })
        assertEquals(listOf("beta", "alpha", "zulu"), sortProjects(projects, ProjectOverviewSort.ATTENTION, cards).map { it.id })
        assertEquals(listOf("alpha", "beta", "zulu"), sortProjects(projects, ProjectOverviewSort.NAME, cards).map { it.id })
    }

    @Test fun compactSyncAgeStaysShort() {
        val now = 10_000_000L
        assertNull(compactSyncAge(null, now))
        assertEquals("now", compactSyncAge(now - 20_000L, now))
        assertEquals("2m", compactSyncAge(now - 120_000L, now))
        assertEquals("2h", compactSyncAge(now - 7_200_000L, now))
    }

    private fun project(id: String, name: String) = Project.newBuilder().setId(id).setName(name).build()

    private fun card(lane: String, runtime: String = "idle") = Card.newBuilder()
        .setId("$lane-$runtime")
        .setLane(lane)
        .setRuntime(runtime)
        .build()
}
