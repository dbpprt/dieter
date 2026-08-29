@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.clickable
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.AccountTree
import androidx.compose.material.icons.outlined.CallMerge
import androidx.compose.material.icons.outlined.CallSplit
import androidx.compose.material.icons.outlined.Cancel
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.CloudUpload
import androidx.compose.material.icons.outlined.Commit
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.ExpandLess
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.OpenInNew
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.SmartToy
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.connection.isServerConversationId
import com.dbpprt.dieter.ui.theme.DieterAmber
import com.dbpprt.dieter.ui.theme.DieterBackground
import com.dbpprt.dieter.ui.theme.DieterCoral
import com.dbpprt.dieter.ui.theme.DieterEyes
import com.dbpprt.dieter.ui.theme.DieterLive
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterOutline
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterSurface
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh
import com.dbpprt.dieter.ui.theme.DieterText
import com.dbpprt.dieter.v1.ChangedFile
import com.dbpprt.dieter.v1.PullRequestSummary
import com.dbpprt.dieter.v1.WorkspaceCommit
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive

private val MonoFont = FontFamily.Monospace

private val diffAdditionText: Color
    @Composable get() = if (isSystemInDarkTheme()) Color(0xFF7BD88F) else Color(0xFF1B7F3B)
private val diffAdditionBackground: Color
    @Composable get() = if (isSystemInDarkTheme()) Color(0xFF16281C) else Color(0xFFE7F6EC)
private val diffDeletionText: Color
    @Composable get() = if (isSystemInDarkTheme()) Color(0xFFF1868E) else Color(0xFFBA1A1A)
private val diffDeletionBackground: Color
    @Composable get() = if (isSystemInDarkTheme()) Color(0xFF321C20) else Color(0xFFFBEAEA)

/** The conversation-level Changes destination: changeset review, diffs, and Git/PR actions. */
@Composable
internal fun WorkspaceChangesBody(
    state: DieterUiState,
    model: DieterViewModel,
    active: Boolean,
    modifier: Modifier = Modifier,
) {
    val review = state.workspaceReview
    val card = state.conversation?.detail?.card ?: state.selectedCard
    val latestState by rememberUpdatedState(state)

    LaunchedEffect(active, card?.id) {
        val cardId = card?.id ?: return@LaunchedEffect
        if (!active || !isServerConversationId(cardId)) return@LaunchedEffect
        model.loadWorkspaceSurface()
        // A running agent turn or Git operation keeps the projection moving;
        // refresh at the same conservative cadence as the Mac client.
        while (isActive) {
            delay(5_000)
            val current = latestState
            val busy = current.workspaceReview.operationActive ||
                agentRuntimeActive(current.selectedCard?.runtime.orEmpty()) ||
                current.workspaceReview.changeset?.volatile == true
            if (busy) model.loadWorkspaceSurface()
        }
    }

    if (card == null || !isServerConversationId(card.id)) {
        WorkspaceEmptyState(
            icon = Icons.Outlined.AccountTree,
            title = "Not synced yet",
            detail = "The workspace appears once this conversation reaches the Dieter machine.",
            modifier = modifier,
        )
        return
    }

    val availability = workspaceActionAvailability(card, review)
    val pullRequest = card.pullRequest.takeIf { it.number > 0 }
    val baseBranch = (review.workspace?.baseBranch ?: card.workspace.baseBranch).ifBlank { "base" }
    val workspaceUnlocked = card.initialPromptSentAt.isBlank()

    var operationSheet by remember(card.id) { mutableStateOf<String?>(null) }
    var mergeSheetOpen by remember(card.id) { mutableStateOf(false) }
    var settingsSheetOpen by remember(card.id) { mutableStateOf(false) }
    var confirmAbort by remember(card.id) { mutableStateOf(false) }
    var commentTarget by remember(card.id) { mutableStateOf<UnifiedDiffLine?>(null) }

    Box(modifier) {
        when {
            review.surfaceRemoved -> WorkspaceEmptyState(
                icon = Icons.Outlined.DeleteOutline,
                title = if (review.operation?.kind == GitOperationKinds.ADOPT) "Workspace moved" else "Workspace removed",
                detail = if (review.operation?.kind == GitOperationKinds.ADOPT) {
                    "The checkout and its history now belong to another conversation."
                } else {
                    "The conversation workspace is no longer provisioned."
                },
            )
            review.workspace == null && review.loading -> Column(
                Modifier.fillMaxSize(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                CircularProgressIndicator(Modifier.size(28.dp), strokeWidth = 3.dp)
                Spacer(Modifier.height(12.dp))
                Text("Preparing the conversation workspace…", color = DieterMuted, fontSize = 12.sp)
            }
            review.workspace == null && review.error != null -> WorkspaceEmptyState(
                icon = Icons.Outlined.ErrorOutline,
                title = "Workspace unavailable",
                detail = review.error,
                action = { OutlinedButton(onClick = model::loadWorkspaceSurface) { Text("Retry") } },
            )
            review.workspace == null -> WorkspaceEmptyState(
                icon = Icons.Outlined.AccountTree,
                title = "No workspace yet",
                detail = "This conversation runs in ${ConversationWorkspaceMode.resolve(card.workspaceMode).title.lowercase()} mode." +
                    if (workspaceUnlocked) " You can change that until the first message is sent." else "",
                action = {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (workspaceUnlocked) {
                            OutlinedButton(onClick = { settingsSheetOpen = true }) { Text("Workspace settings") }
                        }
                        Button(onClick = model::loadWorkspaceSurface) { Text("Prepare workspace") }
                    }
                },
            )
            else -> Column(Modifier.fillMaxSize()) {
                if (review.conflicted) {
                    WorkspaceConflictBanner(
                        conflictCount = review.operation?.conflictsCount ?: 0,
                        baseBranch = baseBranch,
                        onReview = { mergeSheetOpen = true },
                    )
                }
                review.operation?.takeIf { GitOperationStatuses.active(it.status) || it.status == "failed" }?.let { operation ->
                    WorkspaceOperationCard(
                        review = review,
                        onCancel = model::cancelWorkspaceGitOperation,
                    )
                }
                if (review.error != null && review.workspace != null) {
                    WorkspaceErrorBanner(review.error, onRetry = model::loadWorkspaceSurface, onDismiss = model::clearWorkspaceError)
                }
                val diffOpen = review.selectedPath.isNotEmpty() || review.selectedCommitSha.isNotEmpty()
                AnimatedContent(
                    targetState = diffOpen,
                    label = "changes-pane",
                    transitionSpec = {
                        if (targetState) {
                            (slideInHorizontally { it / 3 } + fadeIn()).togetherWith(fadeOut())
                        } else {
                            (slideInHorizontally { -it / 3 } + fadeIn()).togetherWith(fadeOut())
                        }
                    },
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                ) { showDiff ->
                    if (showDiff) {
                        WorkspaceDiffPane(
                            state = state,
                            model = model,
                            onCommentLine = { line -> commentTarget = line },
                        )
                    } else {
                        WorkspaceReviewList(
                            state = state,
                            model = model,
                            availability = availability,
                            pullRequest = pullRequest,
                            baseBranch = baseBranch,
                            workspaceUnlocked = workspaceUnlocked,
                            onOperation = { kind ->
                                when (kind) {
                                    GitOperationKinds.REFRESH_PR, GitOperationKinds.CONTINUE_CONFLICT ->
                                        model.startWorkspaceGitOperation(kind)
                                    GitOperationKinds.ABORT_CONFLICT -> confirmAbort = true
                                    else -> operationSheet = kind
                                }
                            },
                            onMerge = { mergeSheetOpen = true },
                            onSettings = { settingsSheetOpen = true },
                        )
                    }
                }
            }
        }
        review.toast?.let { toast ->
            Surface(
                color = DieterSurfaceHigh,
                shape = RoundedCornerShape(20.dp),
                shadowElevation = 6.dp,
                modifier = Modifier.align(Alignment.BottomCenter).padding(16.dp).navigationBarsPadding(),
            ) {
                Row(
                    Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(Icons.Outlined.CheckCircle, null, tint = DieterLive, modifier = Modifier.size(16.dp))
                    Text(toast, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                }
            }
        }
    }

    operationSheet?.let { kind ->
        GitOperationParameterSheet(
            kind = kind,
            state = state,
            baseBranch = baseBranch,
            pullRequestHeadSha = pullRequest?.headSha.orEmpty(),
            onDismiss = { operationSheet = null },
            onStart = { parameters ->
                operationSheet = null
                model.startWorkspaceGitOperation(kind, parameters)
            },
        )
    }
    if (mergeSheetOpen) {
        WorkspaceMergeSheet(
            state = state,
            model = model,
            card = card,
            availability = availability,
            baseBranch = baseBranch,
            onDismiss = { mergeSheetOpen = false },
            onCreatePullRequestInstead = {
                mergeSheetOpen = false
                operationSheet = GitOperationKinds.CREATE_PR
            },
        )
    }
    if (settingsSheetOpen) {
        ConversationWorkspaceSettingsSheet(
            card = card,
            onDismiss = { settingsSheetOpen = false },
            onSave = { mode, branch, base ->
                settingsSheetOpen = false
                model.updateConversationWorkspace(mode, branch, base)
            },
        )
    }
    if (confirmAbort) {
        AlertDialog(
            onDismissRequest = { confirmAbort = false },
            title = { Text("Abort conflicted operation?") },
            text = { Text("The rebase or merge is rolled back and the workspace returns to its previous state.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmAbort = false
                    model.startWorkspaceGitOperation(GitOperationKinds.ABORT_CONFLICT)
                }) { Text("Abort", color = DieterCoral) }
            },
            dismissButton = { TextButton(onClick = { confirmAbort = false }) { Text("Keep resolving") } },
        )
    }
    commentTarget?.let { line ->
        WorkspaceCommentDialog(
            line = line,
            path = review.selectedPath,
            onDismiss = { commentTarget = null },
            onSubmit = { side, lineNumber, body ->
                commentTarget = null
                model.addWorkspaceChangeComment(review.selectedPath, side, lineNumber, body)
            },
        )
    }
}

// MARK: Review list pane

@Composable
private fun WorkspaceReviewList(
    state: DieterUiState,
    model: DieterViewModel,
    availability: WorkspaceActionAvailability,
    pullRequest: PullRequestSummary?,
    baseBranch: String,
    workspaceUnlocked: Boolean,
    onOperation: (String) -> Unit,
    onMerge: () -> Unit,
    onSettings: () -> Unit,
) {
    val review = state.workspaceReview
    val changes = review.changeset
    LazyColumn(
        Modifier.fillMaxSize().testTag("workspace-changes-list"),
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item(key = "summary") {
            WorkspaceSummaryCard(
                state = state,
                model = model,
                availability = availability,
                baseBranch = baseBranch,
                workspaceUnlocked = workspaceUnlocked,
                onOperation = onOperation,
                onSettings = onSettings,
            )
        }
        pullRequest?.let { pr ->
            item(key = "pull-request") {
                PullRequestCard(
                    pullRequest = pr,
                    availability = availability,
                    onRefresh = { onOperation(GitOperationKinds.REFRESH_PR) },
                    onMerge = { onOperation(GitOperationKinds.MERGE_PR) },
                )
            }
        }
        item(key = "actions") {
            WorkspaceActionRow(
                availability = availability,
                hasPullRequest = pullRequest != null,
                baseBranch = baseBranch,
                onOperation = onOperation,
                onMerge = onMerge,
            )
        }
        if (review.conflicted && (review.operation?.conflictsCount ?: 0) > 0) {
            item(key = "conflicts-header") { WorkspaceSectionHeader("Conflicts", review.operation?.conflictsCount ?: 0) }
            items(review.operation?.conflictsList.orEmpty(), key = { "conflict:${it.path}" }) { conflict ->
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    ChangeStatusBadge("!", DieterCoral)
                    Column(Modifier.weight(1f)) {
                        Text(WorkspaceChangePresentation.filename(conflict.path), fontSize = 13.sp, fontWeight = FontWeight.Medium, fontFamily = MonoFont)
                        Text(
                            "${conflict.hunkCount} conflicting hunk${if (conflict.hunkCount == 1) "" else "s"}",
                            color = DieterMuted,
                            fontSize = 11.sp,
                        )
                    }
                }
            }
        }
        val files = changes?.filesList.orEmpty()
        item(key = "files-header") { WorkspaceSectionHeader("Files", files.size) }
        if (files.isEmpty()) {
            item(key = "files-empty") {
                Text(
                    if (changes == null) "Loading changes…" else "No changed files vs $baseBranch.",
                    color = DieterMuted,
                    fontSize = 12.sp,
                    modifier = Modifier.padding(vertical = 6.dp),
                )
            }
        }
        items(files, key = { "file:${it.path}" }) { file ->
            WorkspaceFileRow(
                file = file,
                commentCount = review.comments.count { it.path == file.path },
                onClick = { model.selectWorkspaceChange(file.path) },
            )
        }
        val commits = changes?.commitsList.orEmpty()
        if (commits.isNotEmpty()) {
            item(key = "commits-header") { WorkspaceSectionHeader("Commits", commits.size) }
            items(commits, key = { "commit:${it.sha}" }) { commit ->
                WorkspaceCommitRow(commit) { model.selectWorkspaceChange("", commit.sha) }
            }
        }
        review.scm?.takeIf { !it.authenticated && it.unavailableReason.isNotBlank() }?.let { scm ->
            item(key = "scm-notice") {
                Surface(color = DieterSurface, shape = MaterialTheme.shapes.small) {
                    Row(
                        Modifier.fillMaxWidth().padding(12.dp),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Icon(Icons.Outlined.WarningAmber, null, tint = DieterAmber, modifier = Modifier.size(16.dp))
                        Column {
                            Text("Pull requests unavailable", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                            Text(scm.unavailableReason, color = DieterMuted, fontSize = 11.sp)
                        }
                    }
                }
            }
        }
        if (review.comments.isNotEmpty()) {
            item(key = "comments-header") { WorkspaceSectionHeader("Review comments", review.comments.size) }
            item(key = "comments-handoff") {
                TextButton(onClick = {
                    val summary = state.workspaceReview.comments.joinToString("\n") { comment ->
                        "- ${comment.path}${if (comment.line > 0) ":${comment.line}" else ""} — ${comment.body}"
                    }
                    model.sendWorkspaceHandOffMessage("Please address these review comments:\n$summary")
                }) {
                    Icon(Icons.Outlined.SmartToy, null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Ask the agent to address the review")
                }
            }
        }
        item(key = "bottom-space") { Spacer(Modifier.height(56.dp)) }
    }
}

@Composable
private fun WorkspaceSummaryCard(
    state: DieterUiState,
    model: DieterViewModel,
    availability: WorkspaceActionAvailability,
    baseBranch: String,
    workspaceUnlocked: Boolean,
    onOperation: (String) -> Unit,
    onSettings: () -> Unit,
) {
    val review = state.workspaceReview
    val workspace = review.workspace ?: return
    val changes = review.changeset
    var menuOpen by remember { mutableStateOf(false) }
    Surface(color = DieterSurface, shape = MaterialTheme.shapes.medium) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(
                    if (workspace.mode == "worktree") Icons.Outlined.AccountTree else Icons.Outlined.CallSplit,
                    null,
                    tint = DieterShell,
                    modifier = Modifier.size(16.dp),
                )
                Text(
                    workspace.branch.ifBlank { ConversationWorkspaceMode.resolve(workspace.mode).title },
                    fontFamily = MonoFont,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                if (review.loading) {
                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                } else {
                    IconButton(onClick = model::loadWorkspaceSurface, modifier = Modifier.size(28.dp)) {
                        Icon(Icons.Outlined.Refresh, "Refresh changes", tint = DieterMuted, modifier = Modifier.size(16.dp))
                    }
                }
                Box {
                    IconButton(onClick = { menuOpen = true }, modifier = Modifier.size(28.dp).testTag("workspace-actions-menu")) {
                        Icon(Icons.Outlined.MoreVert, "Workspace actions", tint = DieterMuted, modifier = Modifier.size(16.dp))
                    }
                    WorkspaceOverflowMenu(
                        expanded = menuOpen,
                        onDismiss = { menuOpen = false },
                        availability = availability,
                        workspaceMode = workspace.mode,
                        workspaceUnlocked = workspaceUnlocked,
                        onOperation = { menuOpen = false; onOperation(it) },
                        onSettings = { menuOpen = false; onSettings() },
                    )
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    "${ConversationWorkspaceMode.resolve(workspace.mode).shortTitle} · vs $baseBranch",
                    color = DieterMuted,
                    fontSize = 11.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (workspace.ahead > 0 || workspace.behind > 0) {
                    Text("↑${workspace.ahead} ↓${workspace.behind}", color = DieterMuted, fontSize = 11.sp, fontFamily = MonoFont)
                }
                if (changes != null) {
                    WorkspaceDeltaLabel(changes.additions, changes.deletions)
                    Text(
                        "${changes.filesCount} file${if (changes.filesCount == 1) "" else "s"}",
                        color = DieterMuted,
                        fontSize = 11.sp,
                    )
                }
            }
            val statusLine = workspaceStatusLine(workspace.state, workspace.dirty, changes?.volatile == true)
            if (statusLine != null) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Surface(color = statusLine.second.copy(alpha = 0.14f), shape = CircleShape) {
                        Text(
                            statusLine.first,
                            color = statusLine.second,
                            fontSize = 10.sp,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
                        )
                    }
                }
            }
        }
    }
}

private fun workspaceStatusLine(state: String, dirty: Boolean, volatile: Boolean): Pair<String, Color>? = when {
    state == "conflicted" -> "Conflicted" to Color(0xFFE05B66)
    state == "cleanup_pending" -> "Merged · cleanup pending" to Color(0xFF4CAF80)
    state == "provisioning" || state == "reserved" -> "Provisioning" to Color(0xFF8E8E93)
    state in setOf("orphaned", "recovery_required", "failed") -> "Needs attention · $state" to Color(0xFFE0A93B)
    volatile -> "Agent is working — live view" to Color(0xFF4C9FE0)
    dirty -> "Uncommitted changes" to Color(0xFFE0A93B)
    else -> null
}

@Composable
private fun WorkspaceOverflowMenu(
    expanded: Boolean,
    onDismiss: () -> Unit,
    availability: WorkspaceActionAvailability,
    workspaceMode: String,
    workspaceUnlocked: Boolean,
    onOperation: (String) -> Unit,
    onSettings: () -> Unit,
) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        DropdownMenuItem(
            text = { Text(GitOperationKinds.title(GitOperationKinds.VALIDATE)) },
            leadingIcon = { Icon(Icons.Outlined.CheckCircle, null) },
            enabled = availability.allows(GitOperationKinds.VALIDATE),
            onClick = { onOperation(GitOperationKinds.VALIDATE) },
        )
        DropdownMenuItem(
            text = { Text(GitOperationKinds.title(GitOperationKinds.PUSH)) },
            leadingIcon = { Icon(Icons.Outlined.CloudUpload, null) },
            enabled = availability.allows(GitOperationKinds.PUSH),
            onClick = { onOperation(GitOperationKinds.PUSH) },
        )
        if (workspaceMode == "branch") {
            DropdownMenuItem(
                text = { Text(GitOperationKinds.title(GitOperationKinds.MIGRATE)) },
                leadingIcon = { Icon(Icons.Outlined.AccountTree, null) },
                enabled = availability.allows(GitOperationKinds.MIGRATE),
                onClick = { onOperation(GitOperationKinds.MIGRATE) },
            )
        }
        DropdownMenuItem(
            text = { Text(GitOperationKinds.title(GitOperationKinds.CLEANUP)) },
            leadingIcon = { Icon(Icons.Outlined.DeleteOutline, null) },
            enabled = availability.allows(GitOperationKinds.CLEANUP),
            onClick = { onOperation(GitOperationKinds.CLEANUP) },
        )
        DropdownMenuItem(
            text = { Text(GitOperationKinds.title(GitOperationKinds.DISCARD), color = DieterCoral) },
            leadingIcon = { Icon(Icons.Outlined.DeleteOutline, null, tint = DieterCoral) },
            enabled = availability.allows(GitOperationKinds.DISCARD),
            onClick = { onOperation(GitOperationKinds.DISCARD) },
        )
        if (workspaceUnlocked) {
            HorizontalDivider()
            DropdownMenuItem(
                text = { Text("Workspace settings") },
                leadingIcon = { Icon(Icons.Outlined.Folder, null) },
                onClick = onSettings,
            )
        }
    }
}

@Composable
private fun WorkspaceActionRow(
    availability: WorkspaceActionAvailability,
    hasPullRequest: Boolean,
    baseBranch: String,
    onOperation: (String) -> Unit,
    onMerge: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Button(
            onClick = { onOperation(GitOperationKinds.COMMIT) },
            enabled = availability.allows(GitOperationKinds.COMMIT),
            modifier = Modifier.testTag("workspace-commit"),
        ) {
            Icon(Icons.Outlined.Commit, null, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(6.dp))
            Text("Commit")
        }
        if (availability.workspaceMode != "main") {
            OutlinedButton(
                onClick = onMerge,
                enabled = availability.allowsMergeFlow,
                modifier = Modifier.testTag("workspace-merge"),
            ) {
                Icon(Icons.Outlined.CallMerge, null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text("Merge into $baseBranch")
            }
            OutlinedButton(
                onClick = { onOperation(GitOperationKinds.UPDATE) },
                enabled = availability.allows(GitOperationKinds.UPDATE),
            ) {
                Icon(Icons.Outlined.Sync, null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text("Update")
            }
            if (!hasPullRequest) {
                OutlinedButton(
                    onClick = { onOperation(GitOperationKinds.CREATE_PR) },
                    enabled = availability.allows(GitOperationKinds.CREATE_PR),
                    modifier = Modifier.testTag("workspace-create-pr"),
                ) { Text("Create PR") }
            }
        }
    }
}

@Composable
private fun WorkspaceSectionHeader(title: String, count: Int) {
    Row(
        Modifier.fillMaxWidth().padding(top = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(title.uppercase(), color = DieterMuted, fontSize = 10.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.8.sp)
        Text("$count", color = DieterMuted.copy(alpha = 0.7f), fontSize = 10.sp, fontWeight = FontWeight.Bold)
        HorizontalDivider(Modifier.weight(1f), color = DieterOutline.copy(alpha = 0.4f))
    }
}

@Composable
private fun WorkspaceDeltaLabel(additions: Int, deletions: Int) {
    Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        Text("+$additions", color = diffAdditionText, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, fontFamily = MonoFont)
        Text("−$deletions", color = diffDeletionText, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, fontFamily = MonoFont)
    }
}

@Composable
private fun ChangeStatusBadge(badge: String, tint: Color) {
    Surface(color = tint.copy(alpha = 0.16f), shape = RoundedCornerShape(6.dp)) {
        Text(
            badge,
            color = tint,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            fontFamily = MonoFont,
            modifier = Modifier.padding(horizontal = 7.dp, vertical = 3.dp),
        )
    }
}

@Composable
private fun changeBadgeTint(badge: String): Color = when (badge) {
    "A", "U" -> diffAdditionText
    "D", "!" -> diffDeletionText
    "R", "C" -> DieterEyes
    else -> DieterAmber
}

@Composable
private fun WorkspaceFileRow(file: ChangedFile, commentCount: Int, onClick: () -> Unit) {
    val badge = WorkspaceChangePresentation.badge(file.status, file.conflicted, file.untracked)
    Surface(color = Color.Transparent, shape = MaterialTheme.shapes.small, onClick = onClick) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 2.dp, vertical = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            ChangeStatusBadge(badge, changeBadgeTint(badge))
            Column(Modifier.weight(1f)) {
                Text(
                    WorkspaceChangePresentation.filename(file.path),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                    fontFamily = MonoFont,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                val directory = WorkspaceChangePresentation.directory(file.path)
                val subtitle = buildString {
                    if (file.oldPath.isNotBlank() && file.oldPath != file.path) {
                        append("← ${file.oldPath}")
                    } else if (directory.isNotEmpty()) {
                        append(directory)
                    }
                }
                if (subtitle.isNotEmpty()) {
                    Text(subtitle, color = DieterMuted, fontSize = 10.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            if (commentCount > 0) {
                Surface(color = DieterShell.copy(alpha = 0.16f), shape = CircleShape) {
                    Text(
                        "$commentCount",
                        color = DieterShell,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.padding(horizontal = 6.dp, vertical = 1.dp),
                    )
                }
            }
            if (file.binary) {
                Text("BIN", color = DieterMuted, fontSize = 10.sp, fontWeight = FontWeight.SemiBold)
            } else {
                WorkspaceDeltaLabel(file.additions, file.deletions)
            }
        }
    }
}

@Composable
private fun WorkspaceCommitRow(commit: WorkspaceCommit, onClick: () -> Unit) {
    Surface(color = Color.Transparent, shape = MaterialTheme.shapes.small, onClick = onClick) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 2.dp, vertical = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                commit.shortSha.ifBlank { commit.sha.take(7) },
                color = DieterShell,
                fontSize = 11.sp,
                fontFamily = MonoFont,
                fontWeight = FontWeight.SemiBold,
            )
            Column(Modifier.weight(1f)) {
                Text(commit.subject, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    listOf(commit.authorName, "${commit.changedFiles} file${if (commit.changedFiles == 1) "" else "s"}")
                        .filter(String::isNotBlank)
                        .joinToString(" · "),
                    color = DieterMuted,
                    fontSize = 10.sp,
                )
            }
            WorkspaceDeltaLabel(commit.additions, commit.deletions)
        }
    }
}

// MARK: Pull request card

@Composable
private fun PullRequestCard(
    pullRequest: PullRequestSummary,
    availability: WorkspaceActionAvailability,
    onRefresh: () -> Unit,
    onMerge: () -> Unit,
) {
    val uriHandler = LocalUriHandler.current
    val stateColor = when {
        pullRequest.state == "merged" -> DieterEyes
        pullRequest.state == "closed" -> DieterCoral
        pullRequest.draft -> DieterMuted
        else -> diffAdditionText
    }
    val stateLabel = when {
        pullRequest.draft && pullRequest.state == "open" -> "Draft"
        else -> pullRequest.state.replaceFirstChar(Char::uppercase)
    }
    Surface(color = DieterSurface, shape = MaterialTheme.shapes.medium) {
        Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("PR #${pullRequest.number}", fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                Surface(color = stateColor.copy(alpha = 0.16f), shape = CircleShape) {
                    Text(
                        stateLabel,
                        color = stateColor,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
                    )
                }
                Spacer(Modifier.weight(1f))
                if (pullRequest.url.isNotBlank()) {
                    IconButton(onClick = { uriHandler.openUri(pullRequest.url) }, modifier = Modifier.size(28.dp)) {
                        Icon(Icons.Outlined.OpenInNew, "Open pull request", tint = DieterMuted, modifier = Modifier.size(15.dp))
                    }
                }
            }
            Row(
                Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                PullRequestSignalChip(
                    label = when (pullRequest.checksState) {
                        "passed" -> "Checks passed"
                        "failed" -> "Checks failed"
                        "running" -> "Checks running"
                        else -> "No checks"
                    },
                    tint = when (pullRequest.checksState) {
                        "passed" -> diffAdditionText
                        "failed" -> diffDeletionText
                        "running" -> DieterAmber
                        else -> DieterMuted
                    },
                )
                PullRequestSignalChip(
                    label = when (pullRequest.reviewDecision) {
                        "approved" -> "Approved"
                        "changes_requested" -> "Changes requested"
                        "review_required" -> "Review required"
                        else -> "No review"
                    },
                    tint = when (pullRequest.reviewDecision) {
                        "approved" -> diffAdditionText
                        "changes_requested" -> diffDeletionText
                        else -> DieterMuted
                    },
                )
                PullRequestSignalChip(
                    label = if (pullRequest.mergeable) "Mergeable" else "Not mergeable",
                    tint = if (pullRequest.mergeable) diffAdditionText else DieterAmber,
                )
            }
            if (pullRequest.state == "open") {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(
                        onClick = onRefresh,
                        enabled = availability.allows(GitOperationKinds.REFRESH_PR),
                        modifier = Modifier.weight(1f),
                    ) { Text("Refresh") }
                    Button(
                        onClick = onMerge,
                        enabled = availability.allows(GitOperationKinds.MERGE_PR) && pullRequest.mergeable && !pullRequest.draft,
                        modifier = Modifier.weight(1f).testTag("workspace-merge-pr"),
                    ) { Text("Merge PR") }
                }
            }
        }
    }
}

@Composable
private fun PullRequestSignalChip(label: String, tint: Color) {
    Surface(color = tint.copy(alpha = 0.12f), shape = CircleShape) {
        Text(
            label,
            color = tint,
            fontSize = 10.sp,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.padding(horizontal = 9.dp, vertical = 3.dp),
        )
    }
}

// MARK: Banners and operation progress

@Composable
private fun WorkspaceConflictBanner(conflictCount: Int, baseBranch: String, onReview: () -> Unit) {
    Surface(color = DieterCoral.copy(alpha = 0.10f)) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(Icons.Outlined.WarningAmber, null, tint = DieterCoral, modifier = Modifier.size(16.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    if (conflictCount > 0) {
                        "$conflictCount file${if (conflictCount == 1) "" else "s"} conflict with $baseBranch"
                    } else {
                        "This workspace conflicts with $baseBranch"
                    },
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Text("Merge is blocked until conflicts are resolved.", color = DieterMuted, fontSize = 10.sp)
            }
            TextButton(onClick = onReview) { Text("Resolve…", color = DieterCoral, fontSize = 12.sp) }
        }
    }
}

@Composable
private fun WorkspaceErrorBanner(error: String, onRetry: () -> Unit, onDismiss: () -> Unit) {
    Surface(color = DieterAmber.copy(alpha = 0.10f)) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(Icons.Outlined.ErrorOutline, null, tint = DieterAmber, modifier = Modifier.size(15.dp))
            Text(error, color = DieterText, fontSize = 11.sp, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            TextButton(onClick = onRetry) { Text("Retry", fontSize = 11.sp) }
            IconButton(onClick = onDismiss, modifier = Modifier.size(24.dp)) {
                Icon(Icons.Outlined.Cancel, "Dismiss", tint = DieterMuted, modifier = Modifier.size(14.dp))
            }
        }
    }
}

@Composable
private fun WorkspaceOperationCard(review: WorkspaceReviewState, onCancel: () -> Unit) {
    val operation = review.operation ?: return
    var expanded by remember(operation.id) { mutableStateOf(operation.status == "failed") }
    LaunchedEffect(operation.status) { if (operation.status == "failed") expanded = true }
    Surface(color = DieterSurfaceHigh) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (GitOperationStatuses.active(operation.status)) {
                    CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
                } else {
                    Icon(Icons.Outlined.ErrorOutline, null, tint = DieterCoral, modifier = Modifier.size(15.dp))
                }
                Text(GitOperationKinds.title(operation.kind), fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                Text(
                    operation.status.replace('_', ' ').replaceFirstChar(Char::uppercase),
                    color = DieterMuted,
                    fontSize = 11.sp,
                )
                Spacer(Modifier.weight(1f))
                if (GitOperationStatuses.active(operation.status) && operation.status != "waiting_for_resolution") {
                    TextButton(onClick = onCancel) { Text("Cancel", color = DieterCoral, fontSize = 11.sp) }
                }
                IconButton(onClick = { expanded = !expanded }, modifier = Modifier.size(26.dp)) {
                    Icon(
                        if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore,
                        if (expanded) "Hide log" else "Show log",
                        tint = DieterMuted,
                        modifier = Modifier.size(16.dp),
                    )
                }
            }
            AnimatedVisibility(expanded) {
                Column(
                    Modifier
                        .fillMaxWidth()
                        .padding(top = 6.dp, bottom = 4.dp)
                        .background(DieterBackground, MaterialTheme.shapes.small)
                        .padding(10.dp),
                    verticalArrangement = Arrangement.spacedBy(3.dp),
                ) {
                    if (review.operationLogs.isEmpty() && operation.error.isEmpty()) {
                        Text("Waiting for output…", color = DieterMuted, fontSize = 10.sp, fontFamily = MonoFont)
                    }
                    review.operationLogs.takeLast(60).forEach { entry ->
                        Text(entry.message, fontSize = 10.sp, fontFamily = MonoFont, color = DieterText)
                    }
                    operation.validationResultsList.forEach { result ->
                        Text(
                            "${result.name} · exit ${result.exitCode}",
                            fontSize = 10.sp,
                            fontFamily = MonoFont,
                            fontWeight = FontWeight.SemiBold,
                            color = if (result.exitCode == 0) diffAdditionText else diffDeletionText,
                        )
                        if (result.output.isNotBlank() && result.exitCode != 0) {
                            Text(result.output.trim().takeLast(2000), fontSize = 10.sp, fontFamily = MonoFont, color = DieterMuted)
                        }
                    }
                    if (operation.error.isNotEmpty()) {
                        Text(operation.error, fontSize = 10.sp, fontFamily = MonoFont, color = DieterCoral)
                    }
                }
            }
        }
    }
    HorizontalDivider(color = DieterOutline.copy(alpha = 0.4f))
}

// MARK: Diff pane

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun WorkspaceDiffPane(
    state: DieterUiState,
    model: DieterViewModel,
    onCommentLine: (UnifiedDiffLine) -> Unit,
) {
    val review = state.workspaceReview
    val changes = review.changeset
    val file = changes?.filesList?.firstOrNull { it.path == review.selectedPath }
    val commit = changes?.commitsList?.firstOrNull { it.sha == review.selectedCommitSha }
    val commentsByLine = remember(review.comments, review.selectedPath) {
        review.comments.filter { it.path == review.selectedPath }.groupBy { it.side to it.line }
    }
    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            IconButton(onClick = model::closeWorkspaceDiff, modifier = Modifier.testTag("workspace-diff-back")) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back to changes")
            }
            Column(Modifier.weight(1f)) {
                Text(
                    when {
                        commit != null -> commit.subject
                        else -> WorkspaceChangePresentation.filename(review.selectedPath)
                    },
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    fontFamily = if (commit == null) MonoFont else FontFamily.Default,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    when {
                        commit != null -> "${commit.shortSha.ifBlank { commit.sha.take(7) }} · ${commit.authorName}"
                        file != null -> WorkspaceChangePresentation.title(file.status, file.conflicted, file.untracked) +
                            WorkspaceChangePresentation.directory(review.selectedPath).let { if (it.isEmpty()) "" else " · $it" }
                        else -> ""
                    },
                    color = DieterMuted,
                    fontSize = 10.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (file != null && !file.binary) WorkspaceDeltaLabel(file.additions, file.deletions)
            if (commit != null) WorkspaceDeltaLabel(commit.additions, commit.deletions)
        }
        HorizontalDivider(color = DieterOutline.copy(alpha = 0.5f))
        when {
            review.diff?.binary == true || file?.binary == true -> WorkspaceEmptyState(
                icon = Icons.Outlined.ErrorOutline,
                title = "Binary file",
                detail = "This file cannot be rendered as a text diff.",
            )
            review.diff == null && review.diffLoading -> Column(
                Modifier.fillMaxSize(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) { CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.5.dp) }
            else -> LazyColumn(Modifier.fillMaxSize().testTag("workspace-diff"), contentPadding = PaddingValues(bottom = 32.dp)) {
                items(review.diffLines, key = UnifiedDiffLine::id) { line ->
                    when (line.kind) {
                        UnifiedDiffLine.Kind.HEADER -> if (!line.text.startsWith("diff ")) {
                            Text(
                                line.text,
                                color = DieterMuted,
                                fontSize = 10.sp,
                                fontFamily = MonoFont,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 1.dp),
                            )
                        } else {
                            Spacer(Modifier.height(8.dp))
                        }
                        UnifiedDiffLine.Kind.HUNK -> Surface(color = DieterShell.copy(alpha = 0.08f)) {
                            Text(
                                line.text,
                                color = DieterShell,
                                fontSize = 10.sp,
                                fontFamily = MonoFont,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 3.dp),
                            )
                        }
                        else -> {
                            WorkspaceDiffLineRow(
                                line = line,
                                onLongPress = { onCommentLine(line) },
                            )
                            val key = if (line.newLine != null) "new" to line.newLine else "old" to (line.oldLine ?: 0)
                            commentsByLine[key]?.forEach { comment ->
                                WorkspaceInlineComment(author = comment.author, body = comment.body)
                            }
                        }
                    }
                }
                val diff = review.diff
                if (diff != null && diff.truncated) {
                    item(key = "load-more") {
                        Row(
                            Modifier.fillMaxWidth().padding(vertical = 10.dp),
                            horizontalArrangement = Arrangement.Center,
                        ) {
                            if (review.diffLoading) {
                                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                            } else {
                                OutlinedButton(onClick = model::loadMoreWorkspaceDiff) {
                                    Text(
                                        "Load more · ${diff.nextOffset / 1024} of ${diff.totalBytes / 1024} KB",
                                        fontSize = 11.sp,
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun WorkspaceDiffLineRow(line: UnifiedDiffLine, onLongPress: () -> Unit) {
    val background = when (line.kind) {
        UnifiedDiffLine.Kind.ADDITION -> diffAdditionBackground
        UnifiedDiffLine.Kind.DELETION -> diffDeletionBackground
        else -> Color.Transparent
    }
    val textColor = when (line.kind) {
        UnifiedDiffLine.Kind.ADDITION -> diffAdditionText
        UnifiedDiffLine.Kind.DELETION -> diffDeletionText
        else -> DieterText
    }
    Row(
        Modifier
            .fillMaxWidth()
            .background(background)
            .combinedClickable(onClick = {}, onLongClick = onLongPress),
    ) {
        Text(
            line.oldLine?.toString() ?: "",
            color = DieterMuted.copy(alpha = 0.75f),
            fontSize = 10.sp,
            fontFamily = MonoFont,
            textAlign = androidx.compose.ui.text.style.TextAlign.End,
            modifier = Modifier.width(34.dp).padding(end = 2.dp),
        )
        Text(
            line.newLine?.toString() ?: "",
            color = DieterMuted.copy(alpha = 0.75f),
            fontSize = 10.sp,
            fontFamily = MonoFont,
            textAlign = androidx.compose.ui.text.style.TextAlign.End,
            modifier = Modifier.width(34.dp).padding(end = 6.dp),
        )
        Text(
            line.text,
            color = textColor,
            fontSize = 11.sp,
            fontFamily = MonoFont,
            softWrap = false,
            overflow = TextOverflow.Clip,
            modifier = Modifier.weight(1f).horizontalScroll(rememberScrollState()),
        )
    }
}

@Composable
private fun WorkspaceInlineComment(author: String, body: String) {
    Surface(
        color = DieterShell.copy(alpha = 0.08f),
        shape = RoundedCornerShape(8.dp),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 3.dp),
    ) {
        Column(Modifier.padding(horizontal = 10.dp, vertical = 6.dp)) {
            Text(author.ifBlank { "Comment" }, color = DieterShell, fontSize = 10.sp, fontWeight = FontWeight.SemiBold)
            Text(body, fontSize = 11.sp, color = DieterText)
        }
    }
}

@Composable
private fun WorkspaceCommentDialog(
    line: UnifiedDiffLine,
    path: String,
    onDismiss: () -> Unit,
    onSubmit: (side: String, line: Int, body: String) -> Unit,
) {
    var body by remember { mutableStateOf("") }
    val side = if (line.newLine != null) "new" else "old"
    val lineNumber = line.newLine ?: line.oldLine ?: 0
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add review comment") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    "${WorkspaceChangePresentation.filename(path)} · line $lineNumber",
                    color = DieterMuted,
                    fontSize = 11.sp,
                    fontFamily = MonoFont,
                )
                OutlinedTextField(
                    value = body,
                    onValueChange = { body = it },
                    placeholder = { Text("What should change here?") },
                    minLines = 3,
                    modifier = Modifier.fillMaxWidth(),
                )
                Text("Comments never wake the agent — hand them off explicitly.", color = DieterMuted, fontSize = 10.sp)
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onSubmit(side, lineNumber, body.trim()) },
                enabled = body.isNotBlank(),
            ) { Text("Add comment") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

// MARK: Operation parameter sheet

@Composable
private fun GitOperationParameterSheet(
    kind: String,
    state: DieterUiState,
    baseBranch: String,
    pullRequestHeadSha: String,
    onDismiss: () -> Unit,
    onStart: (Map<String, String>) -> Unit,
) {
    val card = state.conversation?.detail?.card ?: state.selectedCard
    var subject by remember(kind) { mutableStateOf(if (kind == GitOperationKinds.COMMIT) card?.title.orEmpty() else "") }
    var body by remember(kind) { mutableStateOf("") }
    var includeUntracked by remember(kind) { mutableStateOf(true) }
    var validate by remember(kind) { mutableStateOf(true) }
    var draft by remember(kind) { mutableStateOf(false) }
    var strategy by remember(kind) { mutableStateOf("squash") }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = DieterSurfaceHigh) {
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 18.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(GitOperationKinds.title(kind), style = MaterialTheme.typography.titleMedium)
            when (kind) {
                GitOperationKinds.COMMIT -> {
                    OutlinedTextField(
                        value = subject,
                        onValueChange = { subject = it },
                        label = { Text("Commit message") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth().testTag("commit-subject"),
                    )
                    OutlinedTextField(
                        value = body,
                        onValueChange = { body = it },
                        label = { Text("Description (optional)") },
                        minLines = 2,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    WorkspaceSheetToggle("Include untracked files", includeUntracked) { includeUntracked = it }
                }
                GitOperationKinds.UPDATE -> {
                    Text(
                        "Fast-forwards a clean main checkout; otherwise rebases this conversation's branch onto the latest $baseBranch.",
                        color = DieterMuted,
                        fontSize = 12.sp,
                    )
                    WorkspaceSheetToggle("Run validation after updating", validate) { validate = it }
                }
                GitOperationKinds.VALIDATE -> Text(
                    "Runs the project's validation commands in order on the Dieter machine.",
                    color = DieterMuted,
                    fontSize = 12.sp,
                )
                GitOperationKinds.PUSH -> Text(
                    "Pushes the conversation branch to the configured remote. Nothing is merged.",
                    color = DieterMuted,
                    fontSize = 12.sp,
                )
                GitOperationKinds.CREATE_PR -> {
                    OutlinedTextField(
                        value = subject,
                        onValueChange = { subject = it },
                        label = { Text("Title (optional)") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    OutlinedTextField(
                        value = body,
                        onValueChange = { body = it },
                        label = { Text("Description (optional)") },
                        minLines = 2,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    WorkspaceSheetToggle("Open as draft", draft) { draft = it }
                    Text("The branch is pushed first; an existing open PR is reused.", color = DieterMuted, fontSize = 11.sp)
                }
                GitOperationKinds.MERGE_PR -> {
                    Text("Merge strategy", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        listOf("squash" to "Squash", "merge" to "Merge commit", "rebase" to "Rebase").forEach { (value, label) ->
                            FilterChip(selected = strategy == value, onClick = { strategy = value }, label = { Text(label) })
                        }
                    }
                    Text(
                        "The merge is rejected if the remote branch moved past the reviewed revision.",
                        color = DieterMuted,
                        fontSize = 11.sp,
                    )
                }
                GitOperationKinds.MIGRATE -> Text(
                    "Moves this clean branch conversation into an isolated worktree. Files and history are preserved.",
                    color = DieterMuted,
                    fontSize = 12.sp,
                )
                GitOperationKinds.CLEANUP -> Text(
                    "Removes the workspace only when its work is clean and safely integrated. Dieter-managed branches are deleted.",
                    color = DieterMuted,
                    fontSize = 12.sp,
                )
                GitOperationKinds.DISCARD -> {
                    Text(
                        "Removes this workspace and its managed branch, including uncommitted work.",
                        color = DieterCoral,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                    )
                    Text(
                        "Recovery artifacts (branch bundle, patches, untracked archive) are kept on the Dieter machine.",
                        color = DieterMuted,
                        fontSize = 11.sp,
                    )
                }
            }
            Button(
                onClick = {
                    val parameters = when (kind) {
                        GitOperationKinds.COMMIT -> mapOf(
                            "subject" to subject.trim(),
                            "body" to body.trim(),
                            "include_untracked" to if (includeUntracked) "true" else "false",
                        )
                        GitOperationKinds.UPDATE -> mapOf("validate" to if (validate) "true" else "false")
                        GitOperationKinds.CREATE_PR -> buildMap {
                            if (subject.isNotBlank()) put("title", subject.trim())
                            if (body.isNotBlank()) put("body", body.trim())
                            put("draft", if (draft) "true" else "false")
                        }
                        GitOperationKinds.MERGE_PR -> buildMap {
                            put("strategy", strategy)
                            if (pullRequestHeadSha.isNotBlank()) put("expected_head_sha", pullRequestHeadSha)
                        }
                        GitOperationKinds.MIGRATE -> mapOf("mode" to "worktree")
                        else -> emptyMap()
                    }
                    onStart(parameters)
                },
                enabled = kind != GitOperationKinds.COMMIT || subject.isNotBlank(),
                colors = if (GitOperationKinds.destructive(kind)) {
                    androidx.compose.material3.ButtonDefaults.buttonColors(containerColor = DieterCoral)
                } else {
                    androidx.compose.material3.ButtonDefaults.buttonColors()
                },
                modifier = Modifier.fillMaxWidth().testTag("operation-start"),
            ) {
                Text(GitOperationKinds.title(kind))
            }
        }
    }
}

@Composable
private fun WorkspaceSheetToggle(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable { onChange(!checked) },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, fontSize = 13.sp, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

// MARK: Merge sheet

@Composable
private fun WorkspaceMergeSheet(
    state: DieterUiState,
    model: DieterViewModel,
    card: com.dbpprt.dieter.v1.Card,
    availability: WorkspaceActionAvailability,
    baseBranch: String,
    onDismiss: () -> Unit,
    onCreatePullRequestInstead: () -> Unit,
) {
    val review = state.workspaceReview
    val changes = review.changeset
    var strategy by remember { mutableStateOf("squash") }
    var subject by remember { mutableStateOf(card.title) }
    var body by remember { mutableStateOf("") }
    var validate by remember { mutableStateOf(true) }
    var removeWorkspace by remember { mutableStateOf(true) }
    var moveToDone by remember { mutableStateOf(card.scope != "chat") }
    val flowRunning = review.mergeFlowStep != null
    ModalBottomSheet(onDismissRequest = { if (!flowRunning) onDismiss() }, containerColor = DieterSurfaceHigh) {
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 18.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Merge into $baseBranch", style = MaterialTheme.typography.titleMedium)
            changes?.let {
                Text(
                    "${it.filesCount} file${if (it.filesCount == 1) "" else "s"} · " +
                        "${it.commitsCount} commit${if (it.commitsCount == 1) "" else "s"} · +${it.additions} −${it.deletions}",
                    color = DieterMuted,
                    fontSize = 11.sp,
                )
            }
            if (review.conflicted) {
                Surface(color = DieterCoral.copy(alpha = 0.10f), shape = MaterialTheme.shapes.small) {
                    Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("Merge is blocked until conflicts are resolved.", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                        review.operation?.conflictsList.orEmpty().forEach { conflict ->
                            Text(
                                "! ${conflict.path} · ${conflict.hunkCount} hunk${if (conflict.hunkCount == 1) "" else "s"}",
                                fontSize = 11.sp,
                                fontFamily = MonoFont,
                                color = DieterCoral,
                            )
                        }
                        Text(
                            "Resolve the markers in the changed files, then continue — or hand it to the agent.",
                            color = DieterMuted,
                            fontSize = 11.sp,
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton(
                                onClick = {
                                    onDismiss()
                                    val paths = review.operation?.conflictsList.orEmpty().joinToString("\n") { "- ${it.path}" }
                                    model.sendWorkspaceHandOffMessage(
                                        "Please resolve the merge conflicts in this workspace:\n$paths",
                                    )
                                },
                                modifier = Modifier.weight(1f),
                            ) {
                                Icon(Icons.Outlined.SmartToy, null, modifier = Modifier.size(15.dp))
                                Spacer(Modifier.width(6.dp))
                                Text("Agent resolve", fontSize = 12.sp)
                            }
                            Button(
                                onClick = {
                                    onDismiss()
                                    model.startWorkspaceGitOperation(GitOperationKinds.CONTINUE_CONFLICT)
                                },
                                modifier = Modifier.weight(1f),
                            ) { Text("Continue", fontSize = 12.sp) }
                        }
                        TextButton(onClick = {
                            onDismiss()
                            model.startWorkspaceGitOperation(GitOperationKinds.ABORT_CONFLICT)
                        }) { Text("Abort the conflicted operation", color = DieterCoral, fontSize = 11.sp) }
                    }
                }
            } else {
                OutlinedTextField(
                    value = subject,
                    onValueChange = { subject = it },
                    label = { Text("Commit message") },
                    singleLine = true,
                    enabled = !flowRunning,
                    modifier = Modifier.fillMaxWidth().testTag("merge-subject"),
                )
                Text("Strategy", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf(
                        "squash" to "Squash",
                        "merge_commit" to "Merge commit",
                        "fast_forward" to "Fast-forward",
                    ).forEach { (value, label) ->
                        FilterChip(
                            selected = strategy == value,
                            onClick = { if (!flowRunning) strategy = value },
                            label = { Text(label) },
                        )
                    }
                }
                WorkspaceSheetToggle("Run validation before merging", validate) { if (!flowRunning) validate = it }
                WorkspaceSheetToggle("Remove workspace after merge", removeWorkspace) { if (!flowRunning) removeWorkspace = it }
                if (card.scope != "chat") {
                    WorkspaceSheetToggle("Move card to Done", moveToDone) { if (!flowRunning) moveToDone = it }
                }
                if (review.workspace?.dirty == true) {
                    Text(
                        "Uncommitted changes are committed first with the message above.",
                        color = DieterMuted,
                        fontSize = 11.sp,
                    )
                }
                Text("Runs locally on the Dieter machine · nothing is pushed.", color = DieterMuted, fontSize = 11.sp)
                Button(
                    onClick = {
                        model.runWorkspaceMergeFlow(
                            strategy = strategy,
                            subject = subject.trim(),
                            body = body.trim(),
                            validate = validate,
                            removeWorkspace = removeWorkspace,
                            moveCardToDone = moveToDone,
                        )
                        onDismiss()
                    },
                    enabled = !flowRunning && subject.isNotBlank() && availability.allowsMergeFlow,
                    modifier = Modifier.fillMaxWidth().testTag("merge-confirm"),
                ) {
                    Text(
                        when (review.mergeFlowStep) {
                            "commit" -> "Committing…"
                            "merge" -> "Merging…"
                            "cleanup" -> "Cleaning up…"
                            else -> "Merge into $baseBranch"
                        },
                    )
                }
                if (availability.allows(GitOperationKinds.CREATE_PR)) {
                    TextButton(onClick = onCreatePullRequestInstead, modifier = Modifier.align(Alignment.CenterHorizontally)) {
                        Text("Create a pull request instead", fontSize = 12.sp)
                    }
                }
            }
        }
    }
}

// MARK: Workspace settings sheet (before the first prompt)

@Composable
private fun ConversationWorkspaceSettingsSheet(
    card: com.dbpprt.dieter.v1.Card,
    onDismiss: () -> Unit,
    onSave: (mode: String, branch: String, baseBranch: String) -> Unit,
) {
    var mode by remember { mutableStateOf(ConversationWorkspaceMode.resolve(card.workspaceMode)) }
    var branch by remember { mutableStateOf(card.workspaceBranch) }
    var baseBranch by remember { mutableStateOf(card.workspaceBaseBranch) }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = DieterSurfaceHigh) {
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 18.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Workspace", style = MaterialTheme.typography.titleMedium)
            Text(
                "Where this conversation's agent works. Locked once the first message is sent.",
                color = DieterMuted,
                fontSize = 12.sp,
            )
            ConversationWorkspaceMode.entries.forEach { option ->
                WorkspaceModeOption(option, selected = mode == option) { mode = option }
            }
            OutlinedTextField(
                value = branch,
                onValueChange = { branch = it },
                label = { Text("Branch (optional)") },
                placeholder = { Text("Generated when empty") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = baseBranch,
                onValueChange = { baseBranch = it },
                label = { Text("Base branch (optional)") },
                placeholder = { Text("Project default") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Button(
                onClick = { onSave(mode.wire, branch, baseBranch) },
                modifier = Modifier.fillMaxWidth(),
            ) { Text("Save workspace settings") }
        }
    }
}

@Composable
internal fun WorkspaceModeOption(
    option: ConversationWorkspaceMode,
    selected: Boolean,
    onSelect: () -> Unit,
) {
    Surface(
        color = if (selected) DieterShell.copy(alpha = 0.12f) else DieterSurface,
        shape = MaterialTheme.shapes.small,
        border = androidx.compose.foundation.BorderStroke(
            1.dp,
            if (selected) DieterShell.copy(alpha = 0.5f) else DieterOutline.copy(alpha = 0.5f),
        ),
        onClick = onSelect,
    ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(
                if (option == ConversationWorkspaceMode.WORKTREE) Icons.Outlined.AccountTree else Icons.Outlined.CallSplit,
                null,
                tint = if (selected) DieterShell else DieterMuted,
                modifier = Modifier.size(18.dp),
            )
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(option.title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    if (option == ConversationWorkspaceMode.WORKTREE) {
                        Surface(color = DieterShell.copy(alpha = 0.14f), shape = CircleShape) {
                            Text(
                                "Recommended",
                                color = DieterShell,
                                fontSize = 9.sp,
                                fontWeight = FontWeight.SemiBold,
                                modifier = Modifier.padding(horizontal = 6.dp, vertical = 1.dp),
                            )
                        }
                    }
                }
                Text(option.detail, color = DieterMuted, fontSize = 11.sp)
            }
        }
    }
}

// MARK: Shared empty state

@Composable
private fun WorkspaceEmptyState(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    detail: String,
    modifier: Modifier = Modifier,
    action: (@Composable () -> Unit)? = null,
) {
    Column(
        modifier.fillMaxSize().padding(28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(icon, null, tint = DieterMuted, modifier = Modifier.size(34.dp))
        Spacer(Modifier.height(12.dp))
        Text(title, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
        Spacer(Modifier.height(6.dp))
        Text(
            detail,
            color = DieterMuted,
            fontSize = 12.sp,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            modifier = Modifier.widthIn(max = 300.dp),
        )
        if (action != null) {
            Spacer(Modifier.height(16.dp))
            action()
        }
    }
}
