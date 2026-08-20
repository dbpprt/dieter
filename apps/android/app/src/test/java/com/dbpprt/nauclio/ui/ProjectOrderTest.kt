package com.dbpprt.nauclio.ui

import com.dbpprt.nauclio.v1.Project
import org.junit.Assert.assertEquals
import org.junit.Test

class ProjectOrderTest {
    @Test
    fun `saved project order is applied and new projects are appended`() {
        val projects = listOf(project("beta"), project("alpha"), project("new"))

        val ordered = orderedProjects(projects, listOf("alpha", "missing", "beta"))

        assertEquals(listOf("alpha", "beta", "new"), ordered.map(Project::getId))
    }

    @Test
    fun `dropping a project on a later project moves it after the target`() {
        val moved = moveProjectToTarget(listOf("alpha", "beta", "gamma", "delta"), "alpha", "gamma")

        assertEquals(listOf("beta", "gamma", "alpha", "delta"), moved)
    }

    @Test
    fun `dropping a project on an earlier project moves it before the target`() {
        val moved = moveProjectToTarget(listOf("alpha", "beta", "gamma", "delta"), "delta", "beta")

        assertEquals(listOf("alpha", "delta", "beta", "gamma"), moved)
    }

    @Test
    fun `invalid project drop preserves the current order`() {
        val current = listOf("alpha", "beta")

        assertEquals(current, moveProjectToTarget(current, "alpha", "alpha"))
        assertEquals(current, moveProjectToTarget(current, "missing", "beta"))
        assertEquals(current, moveProjectToTarget(current, "alpha", "missing"))
    }

    private fun project(id: String): Project = Project.newBuilder().setId(id).setName(id).build()
}
