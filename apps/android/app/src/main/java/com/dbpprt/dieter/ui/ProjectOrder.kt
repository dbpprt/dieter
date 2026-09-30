package com.dbpprt.dieter.ui

import com.dbpprt.dieter.api.v1.Project

/** Pinned projects in the shared pin order the core computed. */
internal fun orderedPinnedProjects(projects: List<Project>, pinnedProjectOrder: List<String>): List<Project> {
    val byId = projects.associateBy(Project::id)
    return pinnedProjectOrder.distinct().mapNotNull(byId::get)
}
