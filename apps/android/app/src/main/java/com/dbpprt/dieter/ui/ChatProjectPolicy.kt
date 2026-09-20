package com.dbpprt.dieter.ui

import com.dbpprt.dieter.connection.ProjectReplica
import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.Project
import java.util.Locale

internal fun chatProjectsForQuery(
    projects: List<Project>,
    filteredChats: List<Card>,
    query: String,
): List<Project> = projects.filter { project ->
    query.isBlank() ||
        project.name.contains(query, ignoreCase = true) ||
        filteredChats.any { it.projectId == project.id }
}

internal fun chatProjectOptions(
    projects: List<Project>,
    projectReplicas: Map<String, ProjectReplica>,
): List<Pair<String, String>> = projects
    .sortedBy { it.name.lowercase(Locale.getDefault()) }
    .map { project -> project.id to project.name }
