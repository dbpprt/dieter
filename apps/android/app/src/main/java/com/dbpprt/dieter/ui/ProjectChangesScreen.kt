@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.core.presentation.Counts
import com.dbpprt.dieter.core.workspace.GitOperationKinds
import com.dbpprt.dieter.core.workspace.GitOperations
import com.dbpprt.dieter.ui.theme.DieterAmber
import com.dbpprt.dieter.ui.theme.DieterCoral
import com.dbpprt.dieter.ui.theme.DieterEyes
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterOutline
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh
import com.dbpprt.dieter.api.v1.ChangedFile
import com.dbpprt.dieter.core.workspace.ChangeSection
import com.dbpprt.dieter.core.workspace.ProjectChangesView

/** Local, uncommitted state for the selected registered project checkout. */
@Composable
internal fun ProjectChangesScreen(
    state: DieterUiState,
    model: DieterViewModel,
    expanded: Boolean,
    active: Boolean = true,
    modifier: Modifier = Modifier,
) {
    val review = state.projectChanges
    val problem = review.operationError ?: review.refreshError
    var discardPath by remember(state.selectedProjectId) { mutableStateOf<String?>(null) }
    var commitOpen by remember(state.selectedProjectId) { mutableStateOf(false) }

    LaunchedEffect(active, state.selectedProjectId, expanded) {
        // Side by side, the diff pane opens on the first change; one pane shows the list until a change is chosen.
        if (active) model.loadProjectChanges(selectFirst = expanded)
    }

    Box(modifier) {
        when {
            review.changes == null && review.refreshError == null -> CircularProgressIndicator(
                Modifier.align(Alignment.Center).size(30.dp),
                strokeWidth = 3.dp,
            )
            review.changes == null && problem != null -> EmptyDetail(
                "Changes unavailable",
                problem,
                Icons.Outlined.Description,
                Modifier.fillMaxSize(),
            )
            expanded -> ResizableHorizontalSplitPane(
                dividerTag = "project-changes-pane-divider",
                modifier = Modifier.fillMaxSize(),
                leading = { paneModifier ->
                    ProjectChangeList(state, model, { discardPath = it }, { commitOpen = true }, paneModifier)
                },
                trailing = { paneModifier -> ProjectChangeDiff(state, model, showBack = false, modifier = paneModifier) },
            )
            review.selection != null -> ProjectChangeDiff(state, model, showBack = true, modifier = Modifier.fillMaxSize())
            else -> ProjectChangeList(state, model, { discardPath = it }, { commitOpen = true }, Modifier.fillMaxSize())
        }
    }

    discardPath?.let { path ->
        ConfirmDialog(
            title = "Discard changes to $path?",
            body = "Dieter creates recovery artifacts first, then restores this path to HEAD. Untracked files are removed.",
            confirmLabel = "Discard",
            onDismiss = { discardPath = null },
        ) {
            discardPath = null
            model.startProjectGitOperation(GitOperationKinds.DISCARD_CHANGES, path = path)
        }
    }
    if (commitOpen) {
        ProjectCommitDialog(
            branch = review.changes?.branch.orEmpty(),
            onDismiss = { commitOpen = false },
        ) { subject, body ->
            commitOpen = false
            model.startProjectGitOperation(GitOperationKinds.COMMIT, subject = subject, body = body)
        }
    }
}

@Composable
private fun ProjectChangeList(
    state: DieterUiState,
    model: DieterViewModel,
    onDiscard: (String) -> Unit,
    onCommit: () -> Unit,
    modifier: Modifier,
) {
    val review = state.projectChanges
    val changes = review.changes
    val staged = review.staged
    val unstaged = review.unstaged
    var actionsOpen by remember { mutableStateOf(false) }
    Column(modifier.fillMaxSize()) {
        SimpleScreenHeader(
            "Changes",
            review.summary ?: "Registered checkout",
        ) {
            IconButton(onClick = { model.loadProjectChanges() }, enabled = !review.refreshing) {
                Icon(Icons.Outlined.Refresh, "Refresh project changes")
            }
            Box {
                IconButton(
                    onClick = { actionsOpen = true },
                    enabled = !review.mutationsDisabled,
                    modifier = Modifier.testTag("project-changes-actions"),
                ) { Icon(Icons.Outlined.MoreVert, "More change actions") }
                DropdownMenu(expanded = actionsOpen, onDismissRequest = { actionsOpen = false }) {
                    DropdownMenuItem(
                        text = { Text("Update from remote") },
                        enabled = review.allows(GitOperationKinds.UPDATE),
                        onClick = { actionsOpen = false; model.startProjectGitOperation(GitOperationKinds.UPDATE) },
                        modifier = Modifier.testTag("project-changes-update"),
                    )
                    DropdownMenuItem(
                        text = { Text("Validate changes") },
                        enabled = review.allows(GitOperationKinds.VALIDATE),
                        onClick = { actionsOpen = false; model.startProjectGitOperation(GitOperationKinds.VALIDATE) },
                        modifier = Modifier.testTag("project-changes-validate"),
                    )
                    DropdownMenuItem(
                        text = { Text("Push branch") },
                        enabled = review.allows(GitOperationKinds.PUSH),
                        onClick = { actionsOpen = false; model.startProjectGitOperation(GitOperationKinds.PUSH) },
                        modifier = Modifier.testTag("project-changes-push"),
                    )
                }
            }
        }
        if (review.busy && review.changes != null) {
            Row(
                Modifier.fillMaxWidth().background(DieterSurfaceHigh).padding(horizontal = 14.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                Text(GitOperations.title(review.pendingKind ?: review.operation?.kind.orEmpty()), fontSize = 12.sp, fontWeight = FontWeight.Medium)
            }
        }
        if (changes?.volatile == true) {
            Text(
                "A project-directory conversation is active. This shared change list can keep moving while you work.",
                color = DieterAmber,
                fontSize = 11.sp,
                modifier = Modifier.fillMaxWidth().background(DieterSurfaceHigh).padding(12.dp),
            )
        }
        (review.operationError ?: review.refreshError)?.let {
            Row(
                Modifier.fillMaxWidth().background(DieterCoral.copy(alpha = 0.09f)).padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(it, color = DieterCoral, fontSize = 11.sp, modifier = Modifier.weight(1f), maxLines = 2)
                TextButton(onClick = { model.loadProjectChanges() }) { Text("Retry") }
                TextButton(onClick = model::clearProjectChangesError) { Text("Dismiss") }
            }
        }
        if (staged.isNotEmpty()) {
            Button(
                onClick = onCommit,
                enabled = review.allows(GitOperationKinds.COMMIT),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp)
                    .testTag("project-changes-commit"),
            ) { Text("Commit ${Counts.of(staged.size, "file")}") }
        }
        LazyColumn(
            Modifier.weight(1f),
            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp),
            verticalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            item("staged-header") {
                ProjectChangeSectionHeader(
                    title = "Staged",
                    count = staged.size,
                    action = if (staged.isEmpty()) null else "Unstage all",
                    actionTag = "project-changes-unstage-all",
                    enabled = review.allows(GitOperationKinds.UNSTAGE),
                    onAction = { model.startProjectGitOperation(GitOperationKinds.UNSTAGE) },
                )
            }
            if (staged.isEmpty()) item("staged-empty") { Text("Nothing staged", color = DieterMuted, fontSize = 12.sp, modifier = Modifier.padding(10.dp)) }
            items(staged, key = { "staged:${it.path}" }) { file ->
                ProjectChangeRow(file, ChangeSection.STAGED, review, model, onDiscard)
            }
            item("changes-header") {
                ProjectChangeSectionHeader(
                    title = "Changes",
                    count = unstaged.size,
                    action = if (unstaged.isEmpty()) null else "Stage all",
                    actionTag = "project-changes-stage-all",
                    enabled = review.allows(GitOperationKinds.STAGE),
                    onAction = { model.startProjectGitOperation(GitOperationKinds.STAGE) },
                )
            }
            if (unstaged.isEmpty()) item("changes-empty") {
                Text(
                    if (staged.isEmpty()) "Working tree is clean" else "No unstaged changes",
                    color = DieterMuted,
                    fontSize = 12.sp,
                    modifier = Modifier.padding(10.dp).then(
                        if (staged.isEmpty()) Modifier.testTag("project-changes-clean") else Modifier,
                    ),
                )
            }
            items(unstaged, key = { "unstaged:${it.path}" }) { file ->
                ProjectChangeRow(file, ChangeSection.UNSTAGED, review, model, onDiscard)
            }
        }
    }
}

@Composable
private fun ProjectChangeSectionHeader(
    title: String,
    count: Int,
    action: String?,
    actionTag: String,
    enabled: Boolean,
    onAction: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().padding(start = 10.dp, top = 5.dp, bottom = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            "$title · $count",
            color = DieterMuted,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.weight(1f),
        )
        if (action != null) {
            TextButton(onClick = onAction, enabled = enabled, modifier = Modifier.testTag(actionTag)) {
                Text(action, fontSize = 11.sp)
            }
        }
    }
}

@Composable
private fun ProjectChangeRow(
    file: ChangedFile,
    section: ChangeSection,
    review: ProjectChangesView,
    model: DieterViewModel,
    onDiscard: (String) -> Unit,
) {
    val selected = review.selection == (file.path to section)
    val staged = section == ChangeSection.STAGED
    val move = if (staged) GitOperationKinds.UNSTAGE else GitOperationKinds.STAGE
    val additions = if (staged) file.staged_additions else file.unstaged_additions
    val deletions = if (staged) file.staged_deletions else file.unstaged_deletions
    var menuOpen by remember(file.path, section) { mutableStateOf(false) }
    Surface(
        color = if (selected) DieterShell.copy(alpha = 0.12f) else Color.Transparent,
        shape = RoundedCornerShape(10.dp),
        modifier = Modifier.fillMaxWidth().clickable { model.selectProjectChange(file.path, section) }
            .testTag("project-changes-${section.wire}-${file.path}"),
    ) {
        Row(
            Modifier.padding(start = 11.dp, end = 4.dp, top = 7.dp, bottom = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text(file.path, fontFamily = FontFamily.Monospace, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    Text(if (staged) file.index_status.ifBlank { file.status } else file.worktree_status.ifBlank { file.status }, color = DieterMuted, fontSize = 10.sp)
                    if (additions != 0 || deletions != 0) {
                        Text("+$additions", color = DieterEyes, fontSize = 10.sp)
                        Text("−$deletions", color = DieterCoral, fontSize = 10.sp)
                    }
                }
            }
            Box {
                IconButton(
                    onClick = { menuOpen = true },
                    enabled = review.allows(move) || review.allows(GitOperationKinds.DISCARD_CHANGES),
                ) {
                    Icon(Icons.Outlined.MoreVert, "Actions for ${file.path}")
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { Text(if (staged) "Unstage" else "Stage") },
                        enabled = review.allows(move),
                        onClick = {
                            menuOpen = false
                            model.startProjectGitOperation(move, path = file.path)
                        },
                    )
                    DropdownMenuItem(
                        text = { Text("Discard", color = DieterCoral) },
                        leadingIcon = { Icon(Icons.Outlined.DeleteOutline, null, tint = DieterCoral) },
                        enabled = review.allows(GitOperationKinds.DISCARD_CHANGES),
                        onClick = { menuOpen = false; onDiscard(file.path) },
                    )
                }
            }
        }
    }
}

@Composable
private fun ProjectChangeDiff(
    state: DieterUiState,
    model: DieterViewModel,
    showBack: Boolean,
    modifier: Modifier,
) {
    val review = state.projectChanges
    Column(modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (showBack) IconButton(onClick = model::closeProjectDiff) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back to changes") }
            Column(Modifier.weight(1f)) {
                Text(review.selection?.first ?: "Diff", fontFamily = FontFamily.Monospace, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(review.selection?.second?.wire.orEmpty().replaceFirstChar(Char::uppercase), color = DieterMuted, fontSize = 10.sp)
            }
        }
        HorizontalDivider(color = DieterOutline)
        val diff = review.diff
        if (review.diffLoading && diff == null) {
            CircularProgressIndicator(Modifier.align(Alignment.CenterHorizontally).padding(24.dp).size(26.dp), strokeWidth = 3.dp)
        } else if (diff?.binary == true) {
            EmptyDetail("Binary diff", "This file cannot be rendered as text.", Icons.Outlined.Description, Modifier.weight(1f))
        } else if (diff == null) {
            EmptyDetail("Select a change", "A path can appear in both staged and unstaged sections.", Icons.Outlined.Description, Modifier.weight(1f))
        } else {
            DiffRowsList(review.layout, Modifier.weight(1f).testTag("project-changes-diff")) {
                diffPagesFooter(diff, review.diffMore, review.diffTooLarge, review.diffLoading, model::loadMoreProjectDiff)
            }
        }
    }
}

@Composable
private fun ProjectCommitDialog(branch: String, onDismiss: () -> Unit, onCommit: (String, String) -> Unit) {
    var subject by remember { mutableStateOf("") }
    var body by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Commit staged changes") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Only the staged index is committed on ${branch.ifBlank { "the current branch" }}.", color = DieterMuted, fontSize = 12.sp)
                OutlinedTextField(subject, { subject = it }, label = { Text("Commit subject") }, singleLine = true, modifier = Modifier.testTag("project-commit-subject"))
                OutlinedTextField(body, { body = it }, label = { Text("Optional body") }, minLines = 2)
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onCommit(subject, body) },
                enabled = ProjectChangesView.ready(GitOperationKinds.COMMIT, subject),
                modifier = Modifier.testTag("project-operation-start"),
            ) { Text("Commit") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
