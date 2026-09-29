@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.ViewKanban
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.v1.Board
import com.dbpprt.dieter.v1.Project
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/** The destination is chosen before opening the existing durable task composer. */
@Composable
internal fun CaptureDestinationSheet(
    state: DieterUiState,
    draft: CardCreationDraft,
    savedDrafts: List<CardCreationDraft>,
    onDismiss: () -> Unit,
    onProject: (String) -> Unit,
    onBoard: (String) -> Unit,
    onResumeDraft: (CardCreationDraft) -> Unit,
    onDiscardDraft: (CardCreationDraft) -> Unit,
) {
    var projectStepId by rememberSaveable(draft.id) { mutableStateOf<String?>(null) }
    var projectQuery by rememberSaveable(draft.id) { mutableStateOf("") }
    var boardQuery by rememberSaveable(draft.id, projectStepId) { mutableStateOf("") }
    val project = state.projects.firstOrNull { it.id == projectStepId }
    val allBoards = (state.spaceBoards + state.boards).distinctBy { it.id }.filterNot { it.retired }
    val boards = allBoards.filter { it.projectId == project?.id }
    val query = if (project == null) projectQuery else boardQuery
    val density = LocalDensity.current

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
    ) {
        // Preserve the host's text scaling across the sheet's separate window.
        CompositionLocalProvider(LocalDensity provides density) {
            val keyboard = LocalSoftwareKeyboardController.current
            val focus = LocalFocusManager.current
            val back = { focus.clearFocus(force = true); projectStepId = null }
            BackHandler(enabled = project != null, onBack = back)
            Column(Modifier.fillMaxWidth().heightIn(max = 720.dp).testTag("capture-destination-sheet")) {
                Row(Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, bottom = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                    if (project != null) IconButton(onClick = back) {
                        Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back to projects")
                    }
                    Column(Modifier.weight(1f).padding(start = if (project == null) 12.dp else 4.dp)) {
                        Text(if (project == null) "New task" else "Choose board", style = MaterialTheme.typography.headlineSmall,
                            modifier = Modifier.semantics { heading() })
                        Text(if (project == null) "Choose a project to get started." else "Where should this task go?",
                            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    IconButton(onClick = onDismiss) { Icon(Icons.Outlined.Close, "Close task picker") }
                }
                if (project != null) {
                    ListItem(
                        headlineContent = { Text(project.name, maxLines = 2, overflow = TextOverflow.Ellipsis) },
                        supportingContent = { Text(projectDestinationInfo(project, boards.size, state.presentedProjectReplicas[project.id]?.online == false)) },
                        leadingContent = { CaptureProjectIcon(project) },
                        colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
                        modifier = Modifier.padding(horizontal = 16.dp).clip(MaterialTheme.shapes.medium),
                    )
                }
                OutlinedTextField(
                    value = query,
                    onValueChange = { if (project == null) projectQuery = it else boardQuery = it },
                    placeholder = { Text(if (project == null) "Search projects" else "Search boards") },
                    leadingIcon = { Icon(Icons.Outlined.Search, null) },
                    trailingIcon = if (query.isNotEmpty()) ({
                        IconButton(onClick = { if (project == null) projectQuery = "" else boardQuery = "" }) {
                            Icon(Icons.Outlined.Close, "Clear search")
                        }
                    }) else null,
                    singleLine = true,
                    shape = MaterialTheme.shapes.medium,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp).testTag("capture-destination-search"),
                )
                LazyColumn(Modifier.weight(1f, fill = false).testTag("capture-destination-list"), contentPadding = PaddingValues(bottom = 24.dp)) {
                    if (project == null) {
                        val projects = state.projects.filter { it.name.contains(query.trim(), true) || it.summary.contains(query.trim(), true) }
                        item { CaptureSectionTitle("Projects", projects.size) }
                        if (projects.isEmpty()) item {
                            CaptureEmptyState(if (state.projects.isEmpty()) "No projects yet" else "No matching projects",
                                if (state.projects.isEmpty()) "Connect to a machine and add a project. Your draft is kept on this device."
                                else "Try another project name or clear the search.")
                        }
                        items(projects, key = { "project-${it.id}" }) { candidate ->
                            val count = allBoards.count { it.projectId == candidate.id }
                            CaptureDestinationRow(
                                title = candidate.name,
                                detail = candidate.summary.ifBlank { candidate.path }.takeIf(String::isNotBlank),
                                metadata = projectDestinationInfo(candidate, count, state.presentedProjectReplicas[candidate.id]?.online == false),
                                selected = candidate.id == draft.projectId,
                                enabled = draft.submittedRequest?.let { it.projectId == candidate.id } != false,
                                tag = "capture-project-${candidate.id}",
                                leading = { CaptureProjectIcon(candidate) },
                                onClick = { focus.clearFocus(force = true); keyboard?.hide(); projectStepId = candidate.id; onProject(candidate.id) },
                            )
                        }
                        if (savedDrafts.isNotEmpty() && query.isBlank()) {
                            item { HorizontalDivider(Modifier.padding(vertical = 12.dp)); CaptureSectionTitle("Saved drafts", savedDrafts.size) }
                            items(savedDrafts, key = { "draft-${it.id}" }) { saved ->
                                ListItem(
                                    headlineContent = { Text(saved.title.ifBlank { saved.prompt.ifBlank { "Task with attachments" } }, maxLines = 2, overflow = TextOverflow.Ellipsis) },
                                    supportingContent = { Text(state.projects.firstOrNull { it.id == saved.projectId }?.name ?: "Choose a project to continue") },
                                    leadingContent = { Icon(Icons.Outlined.Description, null) },
                                    trailingContent = {
                                        IconButton(onClick = { onDiscardDraft(saved) }, enabled = saved.submissionId.isBlank()) {
                                            Icon(Icons.Outlined.DeleteOutline, "Discard saved draft")
                                        }
                                    },
                                    modifier = Modifier.clickable(role = Role.Button) { keyboard?.hide(); onResumeDraft(saved) },
                                )
                            }
                        }
                    } else {
                        val filtered = boards.filter { it.name.contains(query.trim(), true) || it.description.contains(query.trim(), true) }
                        item { CaptureSectionTitle("Boards", filtered.size) }
                        if (filtered.isEmpty()) item {
                            CaptureEmptyState(if (boards.isEmpty()) "No active boards" else "No matching boards",
                                if (boards.isEmpty()) "Connect or create a board in this project. Your draft is kept."
                                else "Try another board name or clear the search.")
                        }
                        items(filtered, key = { "board-${it.id}" }) { board ->
                            CaptureDestinationRow(
                                title = board.name,
                                detail = board.description.takeIf(String::isNotBlank),
                                metadata = boardDestinationInfo(board, project, boards.count { it.name == board.name } > 1),
                                selected = board.id == draft.boardId,
                                enabled = draft.submittedRequest?.let { it.boardId == board.id } != false,
                                tag = "capture-board-${board.id}",
                                leading = { Icon(Icons.Outlined.ViewKanban, null, Modifier.size(24.dp), tint = MaterialTheme.colorScheme.primary) },
                                onClick = { keyboard?.hide(); onBoard(board.id) },
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun CaptureDestinationRow(
    title: String, detail: String?, metadata: String, selected: Boolean, enabled: Boolean,
    tag: String, leading: @Composable () -> Unit, onClick: () -> Unit,
) {
    ListItem(
        headlineContent = { Text(title, style = MaterialTheme.typography.titleMedium, maxLines = 2, overflow = TextOverflow.Ellipsis) },
        supportingContent = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                detail?.let { Text(it, maxLines = 2, overflow = TextOverflow.Ellipsis) }
                Text(metadata, style = MaterialTheme.typography.bodySmall)
            }
        },
        leadingContent = leading,
        trailingContent = { Icon(Icons.AutoMirrored.Outlined.KeyboardArrowRight, null) },
        colors = ListItemDefaults.colors(
            containerColor = if (selected) MaterialTheme.colorScheme.surfaceContainerHigh else Color.Transparent,
            headlineColor = MaterialTheme.colorScheme.onSurface.copy(alpha = if (enabled) 1f else 0.38f),
            supportingColor = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = if (enabled) 1f else 0.38f),
        ),
        modifier = Modifier.fillMaxWidth().testTag(tag).semantics { this.selected = selected }
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick),
    )
}

@Composable
private fun CaptureProjectIcon(project: Project) {
    Box(Modifier.size(40.dp).background(stableAccent(project.id), RoundedCornerShape(12.dp)), contentAlignment = Alignment.Center) {
        Text(project.name.trim().take(1).uppercase().ifBlank { "·" }, color = Color.White,
            style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun CaptureSectionTitle(title: String, count: Int) {
    Text("$title · $count", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp).semantics { heading() })
}

@Composable
private fun CaptureEmptyState(title: String, message: String) {
    Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = MaterialTheme.typography.titleMedium)
        Text(message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

private fun projectDestinationInfo(project: Project, boards: Int, offline: Boolean): String = buildList {
    add(if (boards == 1) "1 board" else "$boards boards")
    if (project.checkoutsCount > 1) add("${project.checkoutsCount} checkouts")
    if (offline) add("Offline")
}.joinToString(" · ")

private fun boardDestinationInfo(board: Board, project: Project, duplicateName: Boolean): String = buildList {
    add(when (board.workflow) { "review" -> "Review workflow"; "direct" -> "Direct workflow"; else -> "${board.lanesCount} lanes" })
    val branch = listOf(board.baseRemote.ifBlank { project.baseRemote }, project.baseBranch).filter(String::isNotBlank).joinToString("/")
    if (branch.isNotBlank()) add(branch)
    if (duplicateName) runCatching {
        DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT).withZone(ZoneId.systemDefault()).format(Instant.parse(board.createdAt))
    }.getOrNull()?.let { add("Created $it") }
}.joinToString(" · ")
