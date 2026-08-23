package com.dbpprt.dieter.ui

import com.dbpprt.dieter.connection.ProjectHost
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
    projectHosts: Map<String, ProjectHost>,
): List<Pair<String, String>> = projects
    .sortedBy { it.name.lowercase(Locale.getDefault()) }
    .map { project ->
        val host = projectHosts[project.id]?.hostname?.takeIf(String::isNotBlank)
        project.id to if (host == null) project.name else "${project.name} · $host"
    }
