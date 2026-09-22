package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.Project

internal fun orderedProjects(projects: List<Project>, projectOrder: List<String>): List<Project> {
    if (projects.size < 2 || projectOrder.isEmpty()) return projects

    val projectsById = projects.associateBy(Project::getId)
    val orderedIds = projectOrder.asSequence().filter(projectsById::containsKey).distinct().toSet()
    return buildList(projects.size) {
        projectOrder.asSequence().distinct().mapNotNull(projectsById::get).forEach { add(it) }
        projects.filterNot { it.id in orderedIds }.forEach { add(it) }
    }
}

internal fun orderedPinnedProjects(projects: List<Project>, pinnedProjectOrder: List<String>): List<Project> {
    if (projects.isEmpty() || pinnedProjectOrder.isEmpty()) return emptyList()
    val projectsById = projects.associateBy(Project::getId)
    return pinnedProjectOrder.asSequence().distinct().mapNotNull(projectsById::get).toList()
}

internal fun moveProjectToTarget(projectIds: List<String>, projectId: String, targetProjectId: String): List<String> {
    val sourceIndex = projectIds.indexOf(projectId)
    val targetIndex = projectIds.indexOf(targetProjectId)
    if (sourceIndex < 0 || targetIndex < 0 || sourceIndex == targetIndex) return projectIds

    return projectIds.toMutableList().apply {
        removeAt(sourceIndex)
        add(targetIndex, projectId)
    }
}

/** Input protobuf lists are immutable; reuse their ordered projection until an
 * actual directory or user-order change arrives. */
internal class ProjectOrderProjection {
    private var source: List<Project>? = null
    private var order: List<String>? = null
    private var result: List<Project> = emptyList()

    fun apply(projects: List<Project>, projectOrder: List<String>): List<Project> {
        if (source !== projects || order != projectOrder) {
            result = orderedProjects(projects, projectOrder)
            source = projects
            order = projectOrder
        }
        return result
    }
}
