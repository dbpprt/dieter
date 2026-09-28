package com.dbpprt.dieter.ui

import com.dbpprt.dieter.connection.ProjectReplica
import com.dbpprt.dieter.settings.NavigationFolderPreferences
import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.Project
import java.util.Locale

/** Search organization as well as titles, without changing saved disclosure state. */
internal fun chatsForQuery(
    chats: List<Card>,
    projects: List<Project>,
    folders: NavigationFolderPreferences,
    query: String,
): List<Card> {
    val term = query.trim()
    if (term.isEmpty()) return chats
    val projectIDs = projects.filter { it.name.contains(term, ignoreCase = true) }.map { it.id }.toSet()
    val folderChatIDs = folders.folders.filter { it.name.contains(term, ignoreCase = true) }
        .flatMap { it.itemIDs }.toSet()
    return chats.filter {
        it.title.contains(term, ignoreCase = true) || it.projectId in projectIDs || it.id in folderChatIDs
    }
}

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
