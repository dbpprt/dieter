@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.AddTask
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.RemoveDone
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.ui.theme.DieterAmber
import com.dbpprt.dieter.ui.theme.DieterCoral
import com.dbpprt.dieter.ui.theme.DieterEyes
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterOutline
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh
import com.dbpprt.dieter.v1.ChangedFile

/** Local, uncommitted state for the selected registered project checkout. */
@Composable
internal fun ProjectChangesScreen(
    state: DieterUiState,
    model: DieterViewModel,
    expanded: Boolean,
    modifier: Modifier = Modifier,
) {
    val review = state.projectChanges
    var discardPath by remember(state.selectedProjectId) { mutableStateOf<String?>(null) }
    var commitOpen by remember(state.selectedProjectId) { mutableStateOf(false) }

    LaunchedEffect(state.selectedProjectId) { model.loadProjectChanges() }

    Box(modifier) {
        when {
            review.changeset == null && review.loading -> CircularProgressIndicator(
                Modifier.align(Alignment.Center).size(30.dp),
                strokeWidth = 3.dp,
            )
            review.changeset == null && review.error != null -> EmptyDetail(
                "Changes unavailable",
                review.error,
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
            review.selectedPath.isNotEmpty() -> ProjectChangeDiff(state, model, showBack = true, modifier = Modifier.fillMaxSize())
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
            model.startProjectGitOperation(GitOperationKinds.DISCARD_CHANGES, path)
        }
    }
    if (commitOpen) {
        ProjectCommitDialog(
            branch = review.changeset?.branch.orEmpty(),
            onDismiss = { commitOpen = false },
        ) { subject, body ->
            commitOpen = false
            model.startProjectGitOperation(
                GitOperationKinds.COMMIT,
                parameters = mapOf("subject" to subject, "body" to body, "validate" to "false"),
            )
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
    val changes = review.changeset
    val staged = changes?.filesList?.filter { it.staged }.orEmpty()
    val unstaged = changes?.filesList?.filter { it.unstaged }.orEmpty()
    val disabled = review.operationActive || changes?.volatile == true
    Column(modifier.fillMaxSize()) {
        SimpleScreenHeader(
            "Project changes",
            changes?.let { "${it.filesCount} local ${plural(it.filesCount, "file")} · ${it.branch.ifBlank { "current branch" }}" }
                ?: "Registered checkout",
        ) {
            IconButton(onClick = model::loadProjectChanges, enabled = !review.loading) {
                Icon(Icons.Outlined.Refresh, "Refresh project changes")
            }
        }
        if (review.operationActive) {
            Row(
                Modifier.fillMaxWidth().background(DieterSurfaceHigh).padding(horizontal = 14.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                Text(GitOperationKinds.title(review.operation?.kind.orEmpty()), fontSize = 12.sp, fontWeight = FontWeight.Medium)
            }
        }
        if (changes?.volatile == true) {
            Text(
                "A project-directory conversation is active. Inspection remains available; mutations wait until it finishes.",
                color = DieterAmber,
                fontSize = 11.sp,
                modifier = Modifier.fillMaxWidth().background(DieterSurfaceHigh).padding(12.dp),
            )
        }
        review.error?.let {
            Row(
                Modifier.fillMaxWidth().background(DieterCoral.copy(alpha = 0.09f)).padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(it, color = DieterCoral, fontSize = 11.sp, modifier = Modifier.weight(1f), maxLines = 2)
                TextButton(onClick = model::loadProjectChanges) { Text("Retry") }
                TextButton(onClick = model::clearProjectChangesError) { Text("Dismiss") }
            }
        }
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (unstaged.isNotEmpty()) {
                OutlinedButton(
                    onClick = { model.startProjectGitOperation(GitOperationKinds.STAGE) },
                    enabled = !disabled,
                    modifier = Modifier.testTag("project-changes-stage-all"),
                ) { Text("Stage all") }
            }
            if (staged.isNotEmpty()) {
                OutlinedButton(
                    onClick = { model.startProjectGitOperation(GitOperationKinds.UNSTAGE) },
                    enabled = !disabled,
                    modifier = Modifier.testTag("project-changes-unstage-all"),
                ) { Text("Unstage all") }
                Button(
                    onClick = onCommit,
                    enabled = !disabled,
                    modifier = Modifier.testTag("project-changes-commit"),
                ) { Text("Commit") }
            }
        }
        LazyColumn(
            Modifier.weight(1f),
            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp),
            verticalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            item("staged-header") { ProjectChangeSectionHeader("Staged", staged.size) }
            if (staged.isEmpty()) item("staged-empty") { Text("Nothing staged", color = DieterMuted, fontSize = 12.sp, modifier = Modifier.padding(10.dp)) }
            items(staged, key = { "staged:${it.path}" }) { file ->
                ProjectChangeRow(file, "staged", review, disabled, model, onDiscard)
            }
            item("changes-header") { ProjectChangeSectionHeader("Changes", unstaged.size) }
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
                ProjectChangeRow(file, "unstaged", review, disabled, model, onDiscard)
            }
        }
    }
}

@Composable
private fun ProjectChangeSectionHeader(title: String, count: Int) {
    Text(
        "$title · $count",
        color = DieterMuted,
        fontSize = 11.sp,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier.fillMaxWidth().padding(top = 10.dp, bottom = 4.dp),
    )
}

@Composable
private fun ProjectChangeRow(
    file: ChangedFile,
    section: String,
    review: ProjectChangesState,
    disabled: Boolean,
    model: DieterViewModel,
    onDiscard: (String) -> Unit,
) {
    val selected = review.selectedPath == file.path && review.selectedSection == section
    val additions = if (section == "staged") file.stagedAdditions else file.unstagedAdditions
    val deletions = if (section == "staged") file.stagedDeletions else file.unstagedDeletions
    Surface(
        color = if (selected) DieterShell.copy(alpha = 0.12f) else Color.Transparent,
        shape = RoundedCornerShape(10.dp),
        modifier = Modifier.fillMaxWidth().clickable { model.selectProjectChange(file.path, section) }
            .testTag("project-changes-$section-${file.path}"),
    ) {
        Row(
            Modifier.padding(start = 11.dp, end = 4.dp, top = 7.dp, bottom = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text(file.path, fontFamily = FontFamily.Monospace, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    Text(if (section == "staged") file.indexStatus.ifBlank { file.status } else file.worktreeStatus.ifBlank { file.status }, color = DieterMuted, fontSize = 10.sp)
                    Text("+$additions", color = DieterEyes, fontSize = 10.sp)
                    Text("−$deletions", color = DieterCoral, fontSize = 10.sp)
                }
            }
            TextButton(
                onClick = { model.startProjectGitOperation(if (section == "staged") GitOperationKinds.UNSTAGE else GitOperationKinds.STAGE, file.path) },
                enabled = !disabled,
            ) { Text(if (section == "staged") "Unstage" else "Stage", fontSize = 11.sp) }
            IconButton(onClick = { onDiscard(file.path) }, enabled = !disabled) {
                Icon(Icons.Outlined.DeleteOutline, "Discard ${file.path}", tint = DieterCoral)
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
                Text(review.selectedPath.ifBlank { "Diff" }, fontFamily = FontFamily.Monospace, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(review.selectedSection.replaceFirstChar(Char::uppercase), color = DieterMuted, fontSize = 10.sp)
            }
        }
        HorizontalDivider(color = DieterOutline)
        if (review.diffLoading && review.diff == null) {
            CircularProgressIndicator(Modifier.align(Alignment.CenterHorizontally).padding(24.dp).size(26.dp), strokeWidth = 3.dp)
        } else if (review.diff?.binary == true) {
            EmptyDetail("Binary diff", "This file cannot be rendered as text.", Icons.Outlined.Description, Modifier.weight(1f))
        } else if (review.diff == null) {
            EmptyDetail("Select a change", "A path can appear in both staged and unstaged sections.", Icons.Outlined.Description, Modifier.weight(1f))
        } else {
            LazyColumn(
                Modifier.weight(1f).horizontalScroll(rememberScrollState()),
                contentPadding = PaddingValues(vertical = 8.dp),
            ) {
                items(review.diffLines, key = { it.id }) { line ->
                    Text(
                        line.text.ifEmpty { " " },
                        color = when (line.kind) {
                            UnifiedDiffLine.Kind.ADDITION -> DieterEyes
                            UnifiedDiffLine.Kind.DELETION -> DieterCoral
                            UnifiedDiffLine.Kind.HUNK -> DieterShell
                            UnifiedDiffLine.Kind.HEADER -> DieterMuted
                            UnifiedDiffLine.Kind.CONTEXT -> MaterialTheme.colorScheme.onSurface
                        },
                        fontFamily = FontFamily.Monospace,
                        fontSize = 11.sp,
                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 1.dp),
                    )
                }
                if (review.diff?.truncated == true) {
                    item("load-more") { TextButton(onClick = model::loadMoreProjectDiff) { Text("Load more") } }
                }
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
            TextButton(onClick = { onCommit(subject.trim(), body) }, enabled = subject.isNotBlank(), modifier = Modifier.testTag("project-operation-start")) { Text("Commit") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
