@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
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
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.AccountTree
import androidx.compose.material.icons.outlined.CallMerge
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.ChangeComment
import com.dbpprt.dieter.api.v1.ChangedFile
import com.dbpprt.dieter.api.v1.FileDiff
import com.dbpprt.dieter.api.v1.WorkspaceCommit
import com.dbpprt.dieter.core.composition.WorkspaceMode
import com.dbpprt.dieter.core.outbox.OutboxPolicy
import com.dbpprt.dieter.core.presentation.Ages
import com.dbpprt.dieter.core.presentation.ByteSizes
import com.dbpprt.dieter.core.presentation.Counts
import com.dbpprt.dieter.core.runtime.Timestamps
import com.dbpprt.dieter.core.workspace.ChangedFiles
import com.dbpprt.dieter.core.workspace.Commits
import com.dbpprt.dieter.core.workspace.DiffLayout
import com.dbpprt.dieter.core.workspace.DiffLine
import com.dbpprt.dieter.core.workspace.DiffLineKind
import com.dbpprt.dieter.core.workspace.DiffPages
import com.dbpprt.dieter.core.workspace.DiffRow
import com.dbpprt.dieter.core.workspace.GitFormCopy
import com.dbpprt.dieter.core.workspace.GitFormField
import com.dbpprt.dieter.core.workspace.GitOperationForm
import com.dbpprt.dieter.core.workspace.GitOperationKinds
import com.dbpprt.dieter.core.workspace.GitOperations
import com.dbpprt.dieter.core.workspace.MergeReadinessItem
import com.dbpprt.dieter.core.workspace.MergeStep
import com.dbpprt.dieter.core.workspace.MergeStrategy
import com.dbpprt.dieter.core.workspace.OperationStart
import com.dbpprt.dieter.core.workspace.PullRequestView
import com.dbpprt.dieter.core.workspace.ReviewComments
import com.dbpprt.dieter.core.workspace.ReviewPresentation
import com.dbpprt.dieter.core.workspace.StatusTone
import com.dbpprt.dieter.core.workspace.WorkspaceAvailability
import com.dbpprt.dieter.core.workspace.WorkspaceReviewView
import com.dbpprt.dieter.core.workspace.WorkspaceStatus
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
import kotlin.time.Clock
import kotlinx.coroutines.delay

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
    if (card != null && WorkspaceMode.of(card) == WorkspaceMode.PROJECT) {
        WorkspaceEmptyState(
            icon = Icons.Outlined.Folder,
            title = "Changes belong to the project",
            detail = "This conversation uses the shared project directory. Its local changes are shown once for the checkout, independent of any card.",
            action = {
                Button(onClick = model::openProjectChanges, modifier = Modifier.testTag("changes-open-project")) {
                    Text("Open project changes")
                }
            },
            modifier = modifier,
        )
        return
    }
    LaunchedEffect(active, card?.id) {
        // The core's review session keeps refreshing while the conversation is open; showing the tab reads at once.
        val cardId = card?.id ?: return@LaunchedEffect
        if (active && OutboxPolicy.isServerBacked(cardId)) model.loadWorkspaceSurface()
    }

    if (card == null || !OutboxPolicy.isServerBacked(card.id)) {
        WorkspaceEmptyState(
            icon = Icons.Outlined.AccountTree,
            title = "Not synced yet",
            detail = "The workspace appears once this conversation reaches the Dieter machine.",
            modifier = modifier,
        )
        return
    }

    val availability = review.availability(card)
    val presentation = ReviewPresentation.of(review, card)
    val pullRequest = presentation.pullRequest
    val baseBranch = presentation.base
    val workspaceUnlocked = WorkspaceStatus.settingsEditable(card)

    var operationSheet by remember(card.id) { mutableStateOf<String?>(null) }
    var mergeSheetOpen by remember(card.id) { mutableStateOf(false) }
    var settingsSheetOpen by remember(card.id) { mutableStateOf(false) }
    var confirmAbort by remember(card.id) { mutableStateOf(false) }
    var commentTarget by remember(card.id) { mutableStateOf<DiffLine?>(null) }
    LaunchedEffect(review.toast) {
        if (review.toast == null) return@LaunchedEffect
        delay(6_000)
        model.clearWorkspaceToast()
    }

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
                detail = review.error.orEmpty(),
                action = { OutlinedButton(onClick = model::loadWorkspaceSurface) { Text("Retry") } },
            )
            review.workspace == null -> WorkspaceEmptyState(
                icon = Icons.Outlined.AccountTree,
                title = "No workspace yet",
                detail = "This conversation runs in ${WorkspaceMode.parse(card.workspace_mode).title.lowercase()} mode." +
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
                        title = presentation.conflictTitle,
                        onReview = { mergeSheetOpen = true },
                    )
                }
                if (presentation.operationVisible) {
                    WorkspaceOperationCard(
                        review = review,
                        cancelable = presentation.operationCancelable,
                        onCancel = model::cancelWorkspaceGitOperation,
                    )
                }
                val error = review.error
                if (error != null && review.workspace != null) {
                    WorkspaceErrorBanner(error, onRetry = model::loadWorkspaceSurface, onDismiss = model::clearWorkspaceError)
                }
                val diffOpen = review.selectedPath != null || review.selectedCommit != null
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
                                when (GitOperations.start(kind)) {
                                    OperationStart.IMMEDIATE -> model.startWorkspaceGitOperation(GitOperationForm.initial(kind, card))
                                    OperationStart.CONFIRM -> confirmAbort = true
                                    OperationStart.FORM -> operationSheet = kind
                                }
                            },
                            onMerge = { mergeSheetOpen = true },
                            onSettings = { settingsSheetOpen = true },
                            onAskAgent = { prompt -> model.sendWorkspaceHandOffMessage(prompt) },
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
            card = card,
            baseBranch = baseBranch,
            onDismiss = { operationSheet = null },
            onStart = { form ->
                operationSheet = null
                model.startWorkspaceGitOperation(form)
            },
        )
    }
    if (mergeSheetOpen) {
        WorkspaceMergeSheet(
            state = state,
            model = model,
            card = card,
            availability = availability,
            presentation = presentation,
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
                    model.startWorkspaceGitOperation(GitOperationForm.initial(GitOperationKinds.ABORT_CONFLICT, card))
                }) { Text("Abort", color = DieterCoral) }
            },
            dismissButton = { TextButton(onClick = { confirmAbort = false }) { Text("Keep resolving") } },
        )
    }
    commentTarget?.let { line ->
        WorkspaceCommentDialog(
            line = line,
            path = review.selectedPath.orEmpty(),
            onDismiss = { commentTarget = null },
            onSubmit = { body ->
                commentTarget = null
                model.addWorkspaceChangeComment(line, body)
            },
        )
    }
}

// MARK: Review list pane

@Composable
private fun WorkspaceReviewList(
    state: DieterUiState,
    model: DieterViewModel,
    availability: WorkspaceAvailability,
    pullRequest: PullRequestView?,
    baseBranch: String,
    workspaceUnlocked: Boolean,
    onOperation: (String) -> Unit,
    onMerge: () -> Unit,
    onSettings: () -> Unit,
    onAskAgent: (String) -> Unit,
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
                    onAskAgent = { onAskAgent(pr.askAgentPrompt) },
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
        if (review.conflicted && (review.operation?.conflicts?.size ?: 0) > 0) {
            item(key = "conflicts-header") { WorkspaceSectionHeader("Conflicts", review.operation?.conflicts?.size ?: 0) }
            items(review.operation?.conflicts.orEmpty(), key = { "conflict:${it.path}" }) { conflict ->
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    ChangeStatusBadge("!", DieterCoral)
                    Column(Modifier.weight(1f)) {
                        Text(ChangedFiles.filename(conflict.path), fontSize = 13.sp, fontWeight = FontWeight.Medium, fontFamily = MonoFont)
                        Text(
                            Counts.of(conflict.hunk_count, "conflicting hunk"),
                            color = DieterMuted,
                            fontSize = 11.sp,
                        )
                    }
                }
            }
        }
        val files = changes?.files.orEmpty()
        item(key = "files-header") { WorkspaceSectionHeader("Local changes", files.size) }
        if (files.isEmpty()) {
            item(key = "files-empty") {
                Text(
                    if (changes == null) "Loading changes…" else "No local changes.",
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
        val commits = changes?.commits.orEmpty()
        if (commits.isNotEmpty()) {
            item(key = "commits-header") { WorkspaceSectionHeader("Commits", commits.size) }
            items(commits, key = { "commit:${it.sha}" }) { commit ->
                WorkspaceCommitRow(commit) { model.selectWorkspaceChange("", commit.sha) }
            }
        }
        review.scm?.takeIf { !it.authenticated && it.unavailable_reason.isNotBlank() }?.let { scm ->
            item(key = "scm-notice") {
                Surface(color = DieterSurface, shape = MaterialTheme.shapes.small) {
                    Row(
                        Modifier.fillMaxWidth().padding(12.dp),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Icon(Icons.Outlined.WarningAmber, null, tint = DieterAmber, modifier = Modifier.size(16.dp))
                        Column {
                            Text("Pull requests unavailable", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                            Text(scm.unavailable_reason, color = DieterMuted, fontSize = 11.sp)
                        }
                    }
                }
            }
        }
        if (review.comments.isNotEmpty()) {
            item(key = "comments-header") { WorkspaceSectionHeader("Review comments", review.comments.size) }
            item(key = "comments-handoff") {
                TextButton(onClick = {
                    model.sendWorkspaceHandOffMessage(WorkspaceStatus.reviewPrompt(state.workspaceReview.comments))
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
    availability: WorkspaceAvailability,
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
                    if (WorkspaceMode.parse(workspace.mode) == WorkspaceMode.WORKTREE) Icons.Outlined.AccountTree else Icons.Outlined.Folder,
                    null,
                    tint = DieterShell,
                    modifier = Modifier.size(16.dp),
                )
                Text(
                    workspace.branch.ifBlank { WorkspaceMode.parse(workspace.mode).title },
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
                        workspaceUnlocked = workspaceUnlocked,
                        onOperation = { menuOpen = false; onOperation(it) },
                        onSettings = { menuOpen = false; onSettings() },
                    )
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    "${WorkspaceMode.parse(workspace.mode).shortTitle} · vs $baseBranch",
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
                        Counts.of(changes.files.size, "file"),
                        color = DieterMuted,
                        fontSize = 11.sp,
                    )
                }
            }
            val statusLine = WorkspaceStatus.status(workspace, changes)?.let { (text, tone) -> text to tone.color }
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

private val StatusTone.color: Color
    get() = when (this) {
        StatusTone.DANGER -> Color(0xFFE05B66)
        StatusTone.SUCCESS -> Color(0xFF4CAF80)
        StatusTone.NEUTRAL -> Color(0xFF8E8E93)
        StatusTone.WARNING -> Color(0xFFE0A93B)
        StatusTone.ACTIVE -> Color(0xFF4C9FE0)
    }

@Composable
private fun WorkspaceOverflowMenu(
    expanded: Boolean,
    onDismiss: () -> Unit,
    availability: WorkspaceAvailability,
    workspaceUnlocked: Boolean,
    onOperation: (String) -> Unit,
    onSettings: () -> Unit,
) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        DropdownMenuItem(
            text = { Text(GitOperations.title(GitOperationKinds.VALIDATE)) },
            leadingIcon = { Icon(Icons.Outlined.CheckCircle, null) },
            enabled = availability.allows(GitOperationKinds.VALIDATE),
            onClick = { onOperation(GitOperationKinds.VALIDATE) },
        )
        DropdownMenuItem(
            text = { Text(GitOperations.title(GitOperationKinds.PUSH)) },
            leadingIcon = { Icon(Icons.Outlined.CloudUpload, null) },
            enabled = availability.allows(GitOperationKinds.PUSH),
            onClick = { onOperation(GitOperationKinds.PUSH) },
        )
        DropdownMenuItem(
            text = { Text(GitOperations.title(GitOperationKinds.CLEANUP)) },
            leadingIcon = { Icon(Icons.Outlined.DeleteOutline, null) },
            enabled = availability.allows(GitOperationKinds.CLEANUP),
            onClick = { onOperation(GitOperationKinds.CLEANUP) },
        )
        DropdownMenuItem(
            text = { Text(GitOperations.title(GitOperationKinds.DISCARD), color = DieterCoral) },
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
    availability: WorkspaceAvailability,
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
        if (availability.mode == WorkspaceMode.WORKTREE) {
            OutlinedButton(
                onClick = onMerge,
                enabled = availability.allowsMergeFlow,
                modifier = Modifier.testTag("workspace-merge"),
            ) {
                Icon(Icons.Outlined.CallMerge, null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text("Merge into $baseBranch")
            }
        }
        OutlinedButton(
            onClick = { onOperation(GitOperationKinds.UPDATE) },
            enabled = availability.allows(GitOperationKinds.UPDATE),
        ) {
            Icon(Icons.Outlined.Sync, null, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(6.dp))
            Text("Update")
        }
        if (!hasPullRequest && availability.hasReviewBranch) {
            OutlinedButton(
                onClick = { onOperation(GitOperationKinds.CREATE_PR) },
                enabled = availability.allows(GitOperationKinds.CREATE_PR),
                modifier = Modifier.testTag("workspace-create-pr"),
            ) { Text("Create PR") }
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
    if (additions == 0 && deletions == 0) return
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
    val badge = ChangedFiles.badge(file.status, file.conflicted, file.untracked)
    Surface(color = Color.Transparent, shape = MaterialTheme.shapes.small, onClick = onClick) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 2.dp, vertical = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            ChangeStatusBadge(badge, changeBadgeTint(badge))
            Column(Modifier.weight(1f)) {
                Text(
                    ChangedFiles.filename(file.path),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                    fontFamily = MonoFont,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                val directory = ChangedFiles.directory(file.path)
                val subtitle = buildString {
                    if (file.old_path.isNotBlank() && file.old_path != file.path) {
                        append("← ${file.old_path}")
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
                Commits.shortSha(commit.short_sha, commit.sha),
                color = DieterShell,
                fontSize = 11.sp,
                fontFamily = MonoFont,
                fontWeight = FontWeight.SemiBold,
            )
            Column(Modifier.weight(1f)) {
                Text(commit.subject, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    listOf(commit.author_name, Counts.of(commit.changed_files, "file"))
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
    pullRequest: PullRequestView,
    availability: WorkspaceAvailability,
    onRefresh: () -> Unit,
    onMerge: () -> Unit,
    onAskAgent: () -> Unit,
) {
    val uriHandler = LocalUriHandler.current
    val stateColor = pullRequest.stateTone.color
    val synced = Timestamps.parse(pullRequest.lastSyncedAt)?.let { "synced ${Ages.ago(it, Clock.System.now())}" }
    Surface(color = DieterSurface, shape = MaterialTheme.shapes.medium) {
        Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("PR #${pullRequest.number}", fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                Surface(color = stateColor.copy(alpha = 0.16f), shape = CircleShape) {
                    Text(
                        pullRequest.stateLabel,
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
            if (pullRequest.signals.isNotEmpty() || synced != null) {
                Row(
                    Modifier.horizontalScroll(rememberScrollState()),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    pullRequest.signals.forEach { signal -> PullRequestSignalChip(signal.text, signal.tone.color) }
                    if (synced != null) Text(synced, color = DieterMuted, fontSize = 10.sp)
                }
            }
            if (pullRequest.canAskAgent) {
                OutlinedButton(onClick = onAskAgent, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Outlined.SmartToy, null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Ask the agent to address the review")
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(
                    onClick = onRefresh,
                    enabled = availability.allows(GitOperationKinds.REFRESH_PR),
                    modifier = Modifier.weight(1f),
                ) { Text("Refresh") }
                Button(
                    onClick = onMerge,
                    enabled = availability.allows(GitOperationKinds.MERGE_PR),
                    modifier = Modifier.weight(1f).testTag("workspace-merge-pr"),
                ) {
                    Text(
                        pullRequest.mergeBlockedReason?.let { "Merge PR · $it" } ?: "Merge PR",
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
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
private fun WorkspaceConflictBanner(title: String, onReview: () -> Unit) {
    Surface(color = DieterCoral.copy(alpha = 0.10f)) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(Icons.Outlined.WarningAmber, null, tint = DieterCoral, modifier = Modifier.size(16.dp))
            Column(Modifier.weight(1f)) {
                Text(title, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
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
private fun WorkspaceOperationCard(review: WorkspaceReviewView, cancelable: Boolean, onCancel: () -> Unit) {
    val operation = review.operation ?: return
    var expanded by remember(operation.id) { mutableStateOf(GitOperations.failed(operation)) }
    LaunchedEffect(operation.status) { if (GitOperations.failed(operation)) expanded = true }
    Surface(color = DieterSurfaceHigh) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (GitOperations.isActive(operation)) {
                    CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
                } else {
                    Icon(Icons.Outlined.ErrorOutline, null, tint = DieterCoral, modifier = Modifier.size(15.dp))
                }
                Text(GitOperations.title(operation.kind), fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                Text(
                    GitOperations.statusLabel(operation),
                    color = DieterMuted,
                    fontSize = 11.sp,
                )
                Spacer(Modifier.weight(1f))
                if (cancelable) {
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
                    if (review.logs.isEmpty() && operation.error.isEmpty()) {
                        Text("Waiting for output…", color = DieterMuted, fontSize = 10.sp, fontFamily = MonoFont)
                    }
                    review.logs.takeLast(60).forEach { entry ->
                        Text(entry.message, fontSize = 10.sp, fontFamily = MonoFont, color = DieterText)
                    }
                    operation.validation_results.forEach { result ->
                        Text(
                            "${result.name} · exit ${result.exit_code}",
                            fontSize = 10.sp,
                            fontFamily = MonoFont,
                            fontWeight = FontWeight.SemiBold,
                            color = if (result.exit_code == 0) diffAdditionText else diffDeletionText,
                        )
                        if (result.output.isNotBlank() && result.exit_code != 0) {
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

@Composable
private fun WorkspaceDiffPane(
    state: DieterUiState,
    model: DieterViewModel,
    onCommentLine: (DiffLine) -> Unit,
) {
    val review = state.workspaceReview
    val changes = review.changeset
    val file = changes?.files?.firstOrNull { it.path == review.selectedPath }
    val commit = changes?.commits?.firstOrNull { it.sha == review.selectedCommit }
    val commentsByLine = remember(review.comments, review.selectedPath) { ReviewComments.byLine(review.comments, review.selectedPath) }
    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            IconButton(onClick = { model.selectWorkspaceChange(null) }, modifier = Modifier.testTag("workspace-diff-back")) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back to changes")
            }
            Column(Modifier.weight(1f)) {
                Text(
                    when {
                        commit != null -> commit.subject
                        else -> ChangedFiles.filename(review.selectedPath.orEmpty())
                    },
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    fontFamily = if (commit == null) MonoFont else FontFamily.Default,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    when {
                        commit != null -> "${Commits.shortSha(commit.short_sha, commit.sha)} · ${commit.author_name}"
                        file != null -> ChangedFiles.title(file.status, file.conflicted, file.untracked) +
                            ChangedFiles.directory(review.selectedPath.orEmpty()).let { if (it.isEmpty()) "" else " · $it" }
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
            else -> DiffRowsList(
                layout = review.layout,
                modifier = Modifier.fillMaxSize().testTag("workspace-diff"),
                comments = commentsByLine,
                canComment = review::canComment,
                onComment = onCommentLine,
            ) {
                diffPagesFooter(review.diff, review.diffMore, review.diffTooLarge, review.diffLoading, model::loadMoreWorkspaceDiff)
            }
        }
    }
}

/**
 * A diff's display rows, unified: file and hunk headers with the unchanged
 * gap before each hunk, folds that expand in place, and each line's
 * comments. Which folds are open is view state, reset when the rows change.
 */
@Composable
internal fun DiffRowsList(
    layout: DiffLayout,
    modifier: Modifier = Modifier,
    comments: Map<Pair<String, Int>, List<ChangeComment>> = emptyMap(),
    canComment: (DiffLine) -> Boolean = { false },
    onComment: (DiffLine) -> Unit = {},
    footer: LazyListScope.() -> Unit = {},
) {
    var expandedFolds by remember(layout) { mutableStateOf(emptySet<Int>()) }
    val rows = remember(layout, expandedFolds) {
        layout.rows.flatMap { row ->
            if (row is DiffRow.Fold && row.id in expandedFolds) listOf<DiffRow>(row) + row.lines.map { DiffRow.Line(it) } else listOf(row)
        }
    }
    LazyColumn(modifier, contentPadding = PaddingValues(bottom = 32.dp)) {
        items(rows, key = { diffRowKey(it) }) { row ->
            when (row) {
                is DiffRow.File -> DiffFileRow(row.path)
                is DiffRow.Hunk -> DiffHunkRow(row)
                is DiffRow.Fold -> {
                    val expanded = row.id in expandedFolds
                    DiffFoldRow(row.count, expanded) { expandedFolds = if (expanded) expandedFolds - row.id else expandedFolds + row.id }
                }
                is DiffRow.Line -> Column {
                    WorkspaceDiffLineRow(row.line, onLongPress = if (canComment(row.line)) ({ onComment(row.line) }) else null)
                    ReviewComments.anchor(row.line)?.let(comments::get)?.forEach { comment ->
                        WorkspaceInlineComment(author = comment.author, body = comment.body)
                    }
                }
                // Diffs are laid out unified here; pairs come only with the split layout.
                is DiffRow.Pair -> Unit
            }
        }
        footer()
    }
}

private fun diffRowKey(row: DiffRow): String = when (row) {
    is DiffRow.Line -> "line:${row.id}"
    is DiffRow.Pair -> "pair:${row.id}"
    is DiffRow.File -> "file:${row.id}"
    is DiffRow.Hunk -> "hunk:${row.id}"
    is DiffRow.Fold -> "fold:${row.id}"
}

/** The end of a paged diff: the next page while one is left, else the note that the diff stops at its limit. */
internal fun LazyListScope.diffPagesFooter(diff: FileDiff?, more: Boolean, tooLarge: Boolean, loading: Boolean, onLoadMore: () -> Unit) {
    if (diff != null && more) {
        item(key = "load-more") {
            Row(
                Modifier.fillMaxWidth().padding(vertical = 10.dp),
                horizontalArrangement = Arrangement.Center,
            ) {
                if (loading) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                } else {
                    OutlinedButton(onClick = onLoadMore) {
                        Text(
                            "Load more · ${ByteSizes.format(diff.next_offset)} of ${ByteSizes.format(diff.total_bytes)}",
                            fontSize = 11.sp,
                        )
                    }
                }
            }
        }
    }
    if (tooLarge) {
        item(key = "too-large") {
            Text(
                DiffPages.TOO_LARGE,
                color = DieterMuted,
                fontSize = 11.sp,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 12.dp),
            )
        }
    }
}

@Composable
private fun DiffFileRow(path: String) {
    Text(
        path,
        fontSize = 11.sp,
        fontWeight = FontWeight.SemiBold,
        fontFamily = MonoFont,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier.fillMaxWidth().padding(top = 8.dp).background(DieterSurface).padding(horizontal = 12.dp, vertical = 7.dp),
    )
}

@Composable
private fun DiffHunkRow(hunk: DiffRow.Hunk) {
    Column(Modifier.fillMaxWidth()) {
        if (hunk.skippedLines > 0) {
            Text(
                Counts.of(hunk.skippedLines, "unchanged line"),
                color = DieterMuted,
                fontSize = 10.sp,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
            )
        }
        Row(
            Modifier.fillMaxWidth().background(DieterShell.copy(alpha = 0.08f)).padding(horizontal = 12.dp, vertical = 3.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                hunk.text,
                color = DieterShell,
                fontSize = 10.sp,
                fontFamily = MonoFont,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            WorkspaceDeltaLabel(hunk.additions, hunk.deletions)
        }
    }
}

@Composable
private fun DiffFoldRow(count: Int, expanded: Boolean, onToggle: () -> Unit) {
    val lines = Counts.of(count, "unchanged line")
    Row(
        Modifier.fillMaxWidth().background(DieterSurface).clickable(onClick = onToggle).padding(horizontal = 12.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, null, tint = DieterMuted, modifier = Modifier.size(14.dp))
        Text(if (expanded) "Hide $lines" else lines, color = DieterMuted, fontSize = 10.sp, fontWeight = FontWeight.Medium)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun WorkspaceDiffLineRow(line: DiffLine, onLongPress: (() -> Unit)?) {
    val background = when (line.kind) {
        DiffLineKind.ADDITION -> diffAdditionBackground
        DiffLineKind.DELETION -> diffDeletionBackground
        else -> Color.Transparent
    }
    val textColor = when (line.kind) {
        DiffLineKind.ADDITION -> diffAdditionText
        DiffLineKind.DELETION -> diffDeletionText
        else -> DieterText
    }
    Row(
        Modifier
            .fillMaxWidth()
            .background(background)
            .then(if (onLongPress != null) Modifier.combinedClickable(onClick = {}, onLongClick = onLongPress) else Modifier),
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
    line: DiffLine,
    path: String,
    onDismiss: () -> Unit,
    onSubmit: (body: String) -> Unit,
) {
    var body by remember { mutableStateOf("") }
    val lineNumber = ReviewComments.anchor(line)?.second ?: 0
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add review comment") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    "${ChangedFiles.filename(path)} · line $lineNumber",
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
                onClick = { onSubmit(body.trim()) },
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
    card: Card,
    baseBranch: String,
    onDismiss: () -> Unit,
    onStart: (GitOperationForm) -> Unit,
) {
    var form by remember(kind) { mutableStateOf(GitOperationForm.initial(kind, card)) }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = DieterSurfaceHigh) {
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 18.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(GitOperations.title(kind), style = MaterialTheme.typography.titleMedium)
            val copy = remember(kind) { GitOperations.copy(kind) }
            GitOperations.fields(kind).filter(form::shows).forEach { field ->
                GitOperationField(field, form, copy) { form = it }
            }
            GitOperations.description(kind, baseBranch)?.let { description ->
                Text(
                    description,
                    color = if (GitOperations.destructive(kind)) DieterCoral else DieterMuted,
                    fontSize = 12.sp,
                    fontWeight = if (GitOperations.destructive(kind)) FontWeight.Medium else FontWeight.Normal,
                )
            }
            GitOperations.notice(kind)?.let { notice ->
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(notice.title, color = notice.tone.color, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                    Text(notice.detail, color = DieterMuted, fontSize = 11.sp)
                }
            }
            Button(
                onClick = { onStart(form) },
                enabled = form.ready,
                colors = if (GitOperations.destructive(kind)) {
                    androidx.compose.material3.ButtonDefaults.buttonColors(containerColor = DieterCoral)
                } else {
                    androidx.compose.material3.ButtonDefaults.buttonColors()
                },
                modifier = Modifier.fillMaxWidth().testTag("operation-start"),
            ) {
                Text(GitOperations.title(kind))
            }
        }
    }
}

/** One input of an operation form; [onChange] receives the edited form. */
@Composable
private fun GitOperationField(field: GitFormField, form: GitOperationForm, copy: GitFormCopy, onChange: (GitOperationForm) -> Unit) {
    when (field) {
        GitFormField.SUBJECT -> OutlinedTextField(
            value = form.subject,
            onValueChange = { onChange(form.copy(subject = it)) },
            label = { Text(copy.subject) },
            placeholder = { Text(copy.subjectPlaceholder) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().testTag("${form.kind}-subject"),
        )
        GitFormField.BODY -> OutlinedTextField(
            value = form.body,
            onValueChange = { onChange(form.copy(body = it)) },
            label = { Text(copy.body) },
            placeholder = { Text(copy.bodyPlaceholder) },
            minLines = 2,
            modifier = Modifier.fillMaxWidth(),
        )
        GitFormField.STAGE_ALL -> WorkspaceSheetToggle(copy.stageAll, form.stageAll) { onChange(form.copy(stageAll = it)) }
        GitFormField.FETCH -> WorkspaceSheetToggle(copy.fetch, form.fetch) { onChange(form.copy(fetch = it)) }
        GitFormField.VALIDATE -> WorkspaceSheetToggle(copy.validate, form.validate) { onChange(form.copy(validate = it)) }
        GitFormField.STRATEGY -> Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(copy.strategy, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                GitOperations.strategies(form.kind).forEach { (value, label) ->
                    FilterChip(selected = form.strategy == value, onClick = { onChange(form.copy(strategy = value)) }, label = { Text(label) })
                }
            }
        }
        GitFormField.DRAFT -> WorkspaceSheetToggle(copy.draft, form.draft) { onChange(form.copy(draft = it)) }
        GitFormField.PUSH -> WorkspaceSheetToggle(copy.push, form.push) { onChange(form.copy(push = it)) }
        GitFormField.FORCE_WITH_LEASE -> WorkspaceSheetToggle(copy.forceWithLease, form.forceWithLease) { onChange(form.copy(forceWithLease = it)) }
        GitFormField.EXPECTED_REMOTE_SHA -> Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            OutlinedTextField(
                value = form.expectedRemoteSha,
                onValueChange = { onChange(form.copy(expectedRemoteSha = it)) },
                label = { Text(copy.expectedRemoteSha) },
                placeholder = { Text(copy.expectedRemoteShaPlaceholder) },
                singleLine = true,
                textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = MonoFont),
                modifier = Modifier.fillMaxWidth(),
            )
            Text(copy.expectedRemoteShaHelp, color = DieterMuted, fontSize = 11.sp)
        }
        GitFormField.TARGET_CARD_ID -> OutlinedTextField(
            value = form.targetCardId,
            onValueChange = { onChange(form.copy(targetCardId = it)) },
            label = { Text(copy.targetCardId) },
            placeholder = { Text(copy.targetCardIdPlaceholder) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
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
    card: Card,
    availability: WorkspaceAvailability,
    presentation: ReviewPresentation,
    onDismiss: () -> Unit,
    onCreatePullRequestInstead: () -> Unit,
) {
    val review = state.workspaceReview
    val changes = review.changeset
    val readiness = presentation.mergeReadiness
    // The merge commits a dirty workspace first; its message starts from the conversation, as a commit's does.
    val commit = remember(card.id) { GitOperationForm.initial(GitOperationKinds.COMMIT, card) }
    var strategy by remember { mutableStateOf(MergeStrategy.entries.first()) }
    var subject by remember { mutableStateOf(commit.subject) }
    var body by remember { mutableStateOf(commit.body) }
    var validate by remember { mutableStateOf(true) }
    var removeWorkspace by remember { mutableStateOf(true) }
    var moveToDone by remember { mutableStateOf(presentation.movesToDone) }
    val flowRunning = review.mergeStep != null
    ModalBottomSheet(onDismissRequest = { if (!flowRunning) onDismiss() }, containerColor = DieterSurfaceHigh) {
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 18.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Merge into ${presentation.base}", style = MaterialTheme.typography.titleMedium)
            changes?.let {
                Text(
                    WorkspaceStatus.summary(it),
                    color = DieterMuted,
                    fontSize = 11.sp,
                )
            }
            if (review.conflicted) {
                Surface(color = DieterCoral.copy(alpha = 0.10f), shape = MaterialTheme.shapes.small) {
                    Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(presentation.conflictTitle, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                        Text("Merge is blocked until conflicts are resolved.", color = DieterMuted, fontSize = 11.sp)
                        review.operation?.conflicts.orEmpty().forEach { conflict ->
                            Text(
                                "! ${WorkspaceStatus.conflict(conflict)}",
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
                                    model.sendWorkspaceHandOffMessage(presentation.conflictPrompt)
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
                                    model.startWorkspaceGitOperation(GitOperationForm.initial(GitOperationKinds.CONTINUE_CONFLICT, card))
                                },
                                enabled = availability.allows(GitOperationKinds.CONTINUE_CONFLICT),
                                modifier = Modifier.weight(1f),
                            ) { Text("Continue", fontSize = 12.sp) }
                        }
                        TextButton(
                            onClick = {
                                onDismiss()
                                model.startWorkspaceGitOperation(GitOperationForm.initial(GitOperationKinds.ABORT_CONFLICT, card))
                            },
                            enabled = availability.allows(GitOperationKinds.ABORT_CONFLICT),
                        ) { Text("Abort the conflicted operation", color = DieterCoral, fontSize = 11.sp) }
                    }
                }
            } else {
                MergeReadinessList(readiness.items)
                OutlinedTextField(
                    value = subject,
                    onValueChange = { subject = it },
                    label = { Text("Commit message") },
                    singleLine = true,
                    enabled = !flowRunning,
                    modifier = Modifier.fillMaxWidth().testTag("merge-subject"),
                )
                if (readiness.commitsFirst) {
                    OutlinedTextField(
                        value = body,
                        onValueChange = { body = it },
                        label = { Text("Description (optional)") },
                        minLines = 2,
                        enabled = !flowRunning,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                Text("Strategy", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    readiness.strategies.forEach { option ->
                        FilterChip(
                            selected = strategy.wire == option.strategy,
                            onClick = { if (!flowRunning) MergeStrategy.entries.firstOrNull { it.wire == option.strategy }?.let { strategy = it } },
                            label = { Text(option.title) },
                        )
                    }
                }
                readiness.strategies.firstOrNull { it.strategy == strategy.wire }?.let { option ->
                    Text(option.caption, color = DieterMuted, fontSize = 11.sp)
                }
                WorkspaceSheetToggle("Run validation before merging", validate) { if (!flowRunning) validate = it }
                WorkspaceSheetToggle("Remove workspace after merge", removeWorkspace) { if (!flowRunning) removeWorkspace = it }
                if (presentation.movesToDone) {
                    WorkspaceSheetToggle("Move card to Done", moveToDone) { if (!flowRunning) moveToDone = it }
                }
                Text(
                    availability.mergeDestination,
                    color = DieterMuted,
                    fontSize = 11.sp,
                )
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
                    enabled = !flowRunning && subject.isNotBlank() && !readiness.blocked && availability.allowsMergeFlow,
                    modifier = Modifier.fillMaxWidth().testTag("merge-confirm"),
                ) {
                    Text(
                        when (review.mergeStep) {
                            MergeStep.COMMIT -> "Committing…"
                            MergeStep.MERGE -> "Merging…"
                            MergeStep.CLEANUP -> "Cleaning up…"
                            null -> readiness.mergeTitle
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

/** The merge checklist: each item with its tone, detail, and how long ago it happened. */
@Composable
private fun MergeReadinessList(items: List<MergeReadinessItem>) {
    if (items.isEmpty()) return
    val now = Clock.System.now()
    Surface(color = DieterSurface, shape = MaterialTheme.shapes.small) {
        Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items.forEach { item ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(item.tone.icon, null, tint = item.tone.color, modifier = Modifier.padding(top = 1.dp).size(14.dp))
                    Column(Modifier.weight(1f)) {
                        Text(item.text, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                        val detail = listOfNotNull(item.detail.ifBlank { null }, Timestamps.parse(item.at)?.let { Ages.ago(it, now) }).joinToString(" · ")
                        if (detail.isNotEmpty()) Text(detail, color = DieterMuted, fontSize = 10.sp)
                    }
                }
            }
        }
    }
}

private val StatusTone.icon: ImageVector
    get() = when (this) {
        StatusTone.DANGER -> Icons.Outlined.ErrorOutline
        StatusTone.WARNING -> Icons.Outlined.WarningAmber
        StatusTone.SUCCESS, StatusTone.NEUTRAL, StatusTone.ACTIVE -> Icons.Outlined.CheckCircle
    }

// MARK: Workspace settings sheet (before the first prompt)

@Composable
private fun ConversationWorkspaceSettingsSheet(
    card: Card,
    onDismiss: () -> Unit,
    onSave: (mode: WorkspaceMode, branch: String, baseBranch: String) -> Unit,
) {
    var mode by remember { mutableStateOf(WorkspaceMode.parse(card.workspace_mode)) }
    var branch by remember { mutableStateOf(card.workspace_branch) }
    var baseBranch by remember { mutableStateOf(card.workspace_base_branch) }
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
            WorkspaceMode.choices.forEach { option ->
                WorkspaceModeOption(option, selected = mode == option) { mode = option }
            }
            if (mode == WorkspaceMode.WORKTREE) {
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
            }
            Button(
                onClick = { onSave(mode, branch, baseBranch) },
                modifier = Modifier.fillMaxWidth(),
            ) { Text("Save workspace settings") }
        }
    }
}

@Composable
internal fun WorkspaceModeOption(
    option: WorkspaceMode,
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
                if (option == WorkspaceMode.WORKTREE) Icons.Outlined.AccountTree else Icons.Outlined.Folder,
                null,
                tint = if (selected) DieterShell else DieterMuted,
                modifier = Modifier.size(18.dp),
            )
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(option.title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    if (option == WorkspaceMode.WORKTREE) {
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
