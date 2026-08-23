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

internal fun moveProjectToTarget(projectIds: List<String>, projectId: String, targetProjectId: String): List<String> {
    val sourceIndex = projectIds.indexOf(projectId)
    val targetIndex = projectIds.indexOf(targetProjectId)
    if (sourceIndex < 0 || targetIndex < 0 || sourceIndex == targetIndex) return projectIds

    return projectIds.toMutableList().apply {
        removeAt(sourceIndex)
        add(targetIndex, projectId)
    }
}
