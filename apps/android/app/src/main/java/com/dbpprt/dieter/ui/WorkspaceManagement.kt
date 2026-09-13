@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.PrimaryTabRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.graphics.toColorInt
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterOutline
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh
import com.dbpprt.dieter.v1.Settings
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import kotlin.random.Random
import com.dbpprt.dieter.ui.theme.DieterAbyss
import com.dbpprt.dieter.connection.EndpointConnection
import com.dbpprt.dieter.connection.EndpointPhase
import com.dbpprt.dieter.data.DIETER_API_VERSION
import com.dbpprt.dieter.v1.Workspace

private enum class ManagementSection(val label: String) {
    PROJECT("Project"),
    BOARD("Board"),
    LIMITS("Limits"),
    ARCHIVES("Archives"),
}

internal data class LabelColorOption(val name: String, val value: String)

internal val LabelColorPalette = listOf(
    LabelColorOption("Ruby", "#d95c68"),
    LabelColorOption("Coral", "#df7650"),
    LabelColorOption("Amber", "#c9952f"),
    LabelColorOption("Lime", "#7d9e45"),
    LabelColorOption("Emerald", "#3e9970"),
    LabelColorOption("Teal", "#379799"),
    LabelColorOption("Sky", "#478dc5"),
    LabelColorOption("Indigo", "#626fd0"),
    LabelColorOption("Violet", "#8a62c3"),
    LabelColorOption("Rose", "#c65f98"),
)

internal fun randomLabelColor(exclude: String = "", random: Random = Random.Default): String {
    val choices = LabelColorPalette.filterNot { it.value.equals(exclude, ignoreCase = true) }
    val available = choices.ifEmpty { LabelColorPalette }
    return available[random.nextInt(available.size)].value
}

@Composable
fun WorkspaceManagementScreen(
    state: DieterUiState,
    model: DieterViewModel,
    contentPadding: PaddingValues,
) {
    val sections = ManagementSection.entries
    val pagerState = rememberPagerState(initialPage = 0, pageCount = { sections.size })
    val scope = rememberCoroutineScope()
    LaunchedEffect(pagerState) {
        snapshotFlow { pagerState.settledPage }
            .distinctUntilChanged()
            .collect { page ->
                if (sections[page] == ManagementSection.ARCHIVES || sections[page] == ManagementSection.LIMITS) {
                    model.loadAdministration()
                }
            }
    }
    Column(Modifier.fillMaxSize().padding(contentPadding)) {
        CreationHeader(
            eyebrow = "Local Dieter",
            title = "Workspace settings",
            subtitle = state.project?.name,
            onClose = model::closeSurface,
            trailing = {
                Button(
                    onClick = { model.openSurface(AppSurface.NEW_PROJECT) },
                    modifier = Modifier.testTag("add-project"),
                ) { Text("Add project") }
            },
        )
        SurfaceErrorBanner(state.error, model::clearError)
        PrimaryTabRow(
            selectedTabIndex = pagerState.currentPage,
            containerColor = MaterialTheme.colorScheme.background,
        ) {
            sections.forEachIndexed { index, item ->
                Tab(
                    selected = pagerState.currentPage == index,
                    onClick = { scope.launch { pagerState.animateScrollToPage(index) } },
                    text = { Text(item.label, fontSize = 13.sp, maxLines = 1) },
                )
            }
        }
        HorizontalPager(
            state = pagerState,
            modifier = Modifier.fillMaxWidth().weight(1f),
            beyondViewportPageCount = 1,
            key = { sections[it] },
        ) { page ->
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)) {
                when (sections[page]) {
                    ManagementSection.PROJECT -> ProjectManagement(state, model)
                    ManagementSection.BOARD -> BoardManagement(state, model)
                    ManagementSection.LIMITS -> LimitsManagement(state, model)
                    ManagementSection.ARCHIVES -> ArchivesManagement(state, model)
                }
                Spacer(Modifier.height(32.dp))
            }
        }
    }
}

@Composable
fun NewProjectScreen(
    state: DieterUiState,
    model: DieterViewModel,
    contentPadding: PaddingValues,
) {
    Column(Modifier.fillMaxSize().padding(contentPadding)) {
        CreationHeader(
            eyebrow = "New workspace",
            title = "Add a Git project",
            onClose = { model.openSurface(AppSurface.WORKSPACE) },
        )
        SurfaceErrorBanner(state.error, model::clearError)
        Column(
            Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 12.dp),
        ) {
            AddProjectManagement(state, model)
            Spacer(Modifier.height(32.dp))
        }
    }
}

@Composable
private fun ProjectManagement(state: DieterUiState, model: DieterViewModel) {
    val project = state.project
    var name by remember(project?.id, project?.name) { mutableStateOf(project?.name.orEmpty()) }
    var summary by remember(project?.id, project?.summary) { mutableStateOf(project?.summary.orEmpty()) }
    var prompt by remember(project?.id, project?.prompt) { mutableStateOf(project?.prompt.orEmpty()) }
    var baseRemote by remember(project?.id, project?.baseRemote) {
        mutableStateOf(project?.baseRemote?.ifBlank { "origin" }.orEmpty())
    }
    var baseBranch by remember(project?.id, project?.baseBranch) {
        mutableStateOf(project?.baseBranch?.ifBlank { "main" }.orEmpty())
    }
    var validationCommands by remember(project?.id, project?.updatedAt) {
        mutableStateOf(project?.validationCommandsList.orEmpty().map(::ValidationCommandDraft))
    }
    var showWorkspaces by remember(project?.id) { mutableStateOf(false) }
    var confirmArchive by remember { mutableStateOf(false) }
    SectionTitle("Project")
    if (project == null) {
        Text("Select or add a project.", color = DieterMuted)
        return
    }
    Text(project.path, color = DieterMuted, style = MaterialTheme.typography.bodySmall)
    Spacer(Modifier.height(8.dp))
    OutlinedTextField(name, { name = it }, label = { Text("Name") }, modifier = Modifier.fillMaxWidth().testTag("project-name"))
    OutlinedTextField(summary, { summary = it }, label = { Text("Summary") }, modifier = Modifier.fillMaxWidth().testTag("project-summary"))
    OutlinedTextField(
        prompt,
        { prompt = it },
        label = { Text("Project instructions") },
        minLines = 4,
        modifier = Modifier.fillMaxWidth().testTag("project-instructions"),
    )
    SectionTitle("Workspace defaults")
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(
            baseRemote,
            { baseRemote = it },
            label = { Text("Base remote") },
            singleLine = true,
            modifier = Modifier.weight(1f).testTag("project-base-remote"),
        )
        OutlinedTextField(
            baseBranch,
            { baseBranch = it },
            label = { Text("Base branch") },
            singleLine = true,
            modifier = Modifier.weight(1f).testTag("project-base-branch"),
        )
    }
    Text(
        "Each chat or card chooses its own workspace mode. These values define its Git base.",
        color = DieterMuted,
        style = MaterialTheme.typography.bodySmall,
    )
    TextButton(
        onClick = { showWorkspaces = true; model.loadProjectWorkspaces() },
        modifier = Modifier.testTag("manage-project-workspaces"),
    ) { Text("Manage existing workspaces…") }
    SectionTitle("Validation commands")
    ValidationCommandsEditor(validationCommands, onChange = { validationCommands = it }, enabled = !state.working)
    val validationError = validationCommandsError(validationCommands)
    validationError?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 10.dp)) {
        Button(
            onClick = {
                model.updateProject(
                    name,
                    summary,
                    prompt,
                    baseRemote,
                    baseBranch,
                    validationCommands.map(ValidationCommandDraft::value),
                )
            },
            enabled = name.isNotBlank() && baseBranch.isNotBlank() && validationError == null && !state.working,
            modifier = Modifier.testTag("save-project-settings"),
        ) { Text("Save project") }
        OutlinedButton(onClick = { confirmArchive = true }, enabled = !state.working) { Text("Archive") }
    }
    if (confirmArchive) {
        AlertDialog(
            onDismissRequest = { confirmArchive = false },
            title = { Text("Archive ${project.name}?") },
            text = { Text("The working tree is untouched. The project can be restored from Archives.") },
            confirmButton = { Button(onClick = { confirmArchive = false; model.archiveCurrentProject() }) { Text("Archive") } },
            dismissButton = { TextButton(onClick = { confirmArchive = false }) { Text("Cancel") } },
        )
    }
    if (showWorkspaces) {
        ProjectWorkspacesSheet(state, model, onDismiss = { showWorkspaces = false })
    }
}

@Composable
private fun ValidationCommandsEditor(
    values: List<ValidationCommandDraft>,
    onChange: (List<ValidationCommandDraft>) -> Unit,
    enabled: Boolean,
) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        values.forEachIndexed { index, command ->
            Surface(
                color = DieterSurfaceHigh,
                shape = RoundedCornerShape(14.dp),
                border = androidx.compose.foundation.BorderStroke(1.dp, DieterOutline),
                modifier = Modifier.fillMaxWidth().testTag("validation-command-$index"),
            ) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(7.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            command.name.ifBlank { command.executable.ifBlank { "New command" } },
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.weight(1f),
                        )
                        TextButton(
                            onClick = { onChange(values.filterNot { it.id == command.id }) },
                            enabled = enabled,
                        ) { Text("Remove", color = MaterialTheme.colorScheme.error) }
                    }
                    fun update(transform: (ValidationCommandDraft) -> ValidationCommandDraft) {
                        onChange(values.map { if (it.id == command.id) transform(it) else it })
                    }
                    OutlinedTextField(
                        command.name,
                        { update { item -> item.copy(name = it) } },
                        label = { Text("Name") },
                        enabled = enabled,
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    OutlinedTextField(
                        command.executable,
                        { update { item -> item.copy(executable = it) } },
                        label = { Text("Executable") },
                        placeholder = { Text("go") },
                        enabled = enabled,
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth().testTag("validation-executable-$index"),
                    )
                    OutlinedTextField(
                        command.arguments,
                        { update { item -> item.copy(arguments = it) } },
                        label = { Text("Arguments — one per line") },
                        enabled = enabled,
                        minLines = 2,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    OutlinedTextField(
                        command.workingDirectory,
                        { update { item -> item.copy(workingDirectory = it) } },
                        label = { Text("Working directory (relative)") },
                        enabled = enabled,
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    OutlinedTextField(
                        command.environment,
                        { update { item -> item.copy(environment = it) } },
                        label = { Text("Environment — KEY=VALUE per line") },
                        enabled = enabled,
                        minLines = 2,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    OutlinedTextField(
                        command.timeoutSeconds,
                        { update { item -> item.copy(timeoutSeconds = it.filter(Char::isDigit)) } },
                        label = { Text("Timeout in seconds") },
                        enabled = enabled,
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }
        OutlinedButton(
            onClick = { onChange(values + ValidationCommandDraft()) },
            enabled = enabled,
            modifier = Modifier.testTag("add-validation-command"),
        ) { Text("＋  Add validation command") }
        Text(
            "Commands run directly in the conversation workspace. Every argument is passed literally as one argv value.",
            color = DieterMuted,
            style = MaterialTheme.typography.bodySmall,
        )
    }
}

@Composable
private fun ProjectWorkspacesSheet(
    state: DieterUiState,
    model: DieterViewModel,
    onDismiss: () -> Unit,
) {
    var candidate by remember { mutableStateOf<Workspace?>(null) }
    var candidateKind by remember { mutableStateOf(GitOperationKinds.CLEANUP) }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = MaterialTheme.colorScheme.background) {
        Column(
            Modifier.fillMaxWidth().heightIn(max = 720.dp).verticalScroll(rememberScrollState())
                .padding(start = 18.dp, end = 18.dp, bottom = 30.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Project workspaces", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                    Text("Conversation-owned checkouts, branches, and recovery state", color = DieterMuted, fontSize = 12.sp)
                }
                TextButton(onClick = model::loadProjectWorkspaces, enabled = !state.projectWorkspacesLoading) {
                    Text("Refresh")
                }
            }
            if (state.projectWorkspacesLoading && state.projectWorkspaces.isEmpty()) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
                    CircularProgressIndicator(Modifier.size(26.dp), strokeWidth = 2.dp)
                }
            } else if (state.projectWorkspaces.isEmpty()) {
                Text(
                    "No provisioned workspaces. A workspace appears when a conversation first uses Git, Files, or a scoped terminal.",
                    color = DieterMuted,
                )
            }
            state.projectWorkspaces.forEach { workspace ->
                val pending = workspace.cardId in state.projectWorkspaceOperations
                Surface(
                    color = DieterSurfaceHigh,
                    shape = RoundedCornerShape(14.dp),
                    border = androidx.compose.foundation.BorderStroke(1.dp, DieterOutline),
                    modifier = Modifier.fillMaxWidth().testTag("project-workspace-${workspace.cardId}"),
                ) {
                    Column(Modifier.padding(13.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                val title = (state.cards + state.chats + state.spaceCards)
                                    .firstOrNull { it.id == workspace.cardId }?.title
                                    .orEmpty().ifBlank { workspace.branch.ifBlank { workspace.cardId } }
                                Text(title, fontWeight = FontWeight.SemiBold, maxLines = 1)
                                Text(
                                    "${workspace.mode.replace('_', ' ')} · ${workspace.state.replace('_', ' ')}",
                                    color = DieterMuted,
                                    fontSize = 11.sp,
                                )
                            }
                            if (pending) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                        }
                        Text(workspace.path, color = DieterMuted, fontSize = 10.sp, maxLines = 1)
                        Text(
                            "${workspace.changedFiles} files · +${workspace.additions} −${workspace.deletions} · ${formatWorkspaceBytes(workspace.sizeBytes)}",
                            color = DieterMuted,
                            fontSize = 11.sp,
                        )
                        state.projectWorkspaceErrors[workspace.cardId]?.let {
                            Text(it, color = MaterialTheme.colorScheme.error, fontSize = 11.sp)
                        }
                        if (workspace.mode == ConversationWorkspaceMode.WORKTREE.wire) {
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                OutlinedButton(
                                    onClick = { candidate = workspace; candidateKind = GitOperationKinds.CLEANUP },
                                    enabled = !pending && workspace.changedFiles == 0,
                                    modifier = Modifier.testTag("cleanup-workspace-${workspace.cardId}"),
                                ) { Text("Clean up") }
                                TextButton(
                                    onClick = { candidate = workspace; candidateKind = GitOperationKinds.DISCARD },
                                    enabled = !pending,
                                    modifier = Modifier.testTag("discard-workspace-${workspace.cardId}"),
                                ) { Text("Discard", color = MaterialTheme.colorScheme.error) }
                            }
                        }
                    }
                }
            }
        }
    }
    candidate?.let { workspace ->
        val discard = candidateKind == GitOperationKinds.DISCARD
        AlertDialog(
            onDismissRequest = { candidate = null },
            title = { Text(if (discard) "Discard workspace?" else "Clean up workspace?") },
            text = {
                Text(
                    if (discard) "Dieter records recovery artifacts, then removes the checkout and managed branch."
                    else "Only clean, integrated workspaces can be cleaned up.",
                )
            },
            confirmButton = {
                Button(
                    onClick = {
                        model.runProjectWorkspaceOperation(workspace, candidateKind)
                        candidate = null
                    },
                    modifier = Modifier.testTag("confirm-workspace-operation"),
                ) { Text(if (discard) "Discard" else "Clean up") }
            },
            dismissButton = { TextButton(onClick = { candidate = null }) { Text("Cancel") } },
        )
    }
}

private fun formatWorkspaceBytes(value: Long): String = when {
    value >= 1_073_741_824L -> String.format("%.1f GB", value / 1_073_741_824.0)
    value >= 1_048_576L -> String.format("%.1f MB", value / 1_048_576.0)
    value >= 1_024L -> String.format("%.1f KB", value / 1_024.0)
    else -> "$value B"
}

@Composable
private fun BoardManagement(state: DieterUiState, model: DieterViewModel) {
    val board = state.board
    var newBoardName by remember { mutableStateOf("") }
    var workflow by remember { mutableStateOf("review") }
    var description by remember { mutableStateOf("") }
    var labelName by remember { mutableStateOf("") }
    var labelColor by remember(board?.id) { mutableStateOf(randomLabelColor()) }
    var baseRemote by remember(board?.id) { mutableStateOf(board?.baseRemote?.ifBlank { state.project?.baseRemote.orEmpty() }.orEmpty()) }
    var remotePublishMode by remember(board?.id) { mutableStateOf(board?.remotePublishMode?.ifBlank { "manual" } ?: "manual") }
    SectionTitle("Current board")
    if (board != null) {
        Text(board.name, fontWeight = FontWeight.SemiBold)
        Text(board.description.ifBlank { "${board.workflow} workflow" }, color = DieterMuted)
        OutlinedTextField(
            baseRemote,
            { baseRemote = it },
            label = { Text("Default Git remote") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
        )
        Text("Remote publishing", color = DieterMuted, modifier = Modifier.padding(top = 8.dp))
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            listOf("manual" to "Manual", "pull_request" to "Pull request", "push_base" to "Push base").forEach { (value, label) ->
                FilterChip(selected = remotePublishMode == value, onClick = { remotePublishMode = value }, label = { Text(label) })
            }
        }
        Button(
            onClick = { model.updateBoardGitSettings(baseRemote, remotePublishMode) },
            enabled = !state.working,
        ) { Text("Save Git defaults") }
        Text("Archive completed cards", color = DieterMuted, modifier = Modifier.padding(top = 8.dp))
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            listOf("never", "immediately", "after_1_day", "after_7_days", "after_30_days", "after_90_days").forEach { policy ->
                FilterChip(
                    selected = board.doneArchivePolicy == policy,
                    onClick = { model.setBoardArchivePolicy(policy) },
                    label = { Text(policy.replace('_', ' ')) },
                )
            }
        }
        SectionTitle("Labels")
        board.labelsList.forEach { label ->
            Row(
                Modifier.fillMaxWidth().padding(vertical = 3.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ManagementLabelPill(label.name, label.color)
                TextButton(onClick = { model.deleteBoardLabel(label.id) }) { Text("Delete") }
            }
        }
        OutlinedTextField(labelName, { labelName = it }, label = { Text("New label") }, modifier = Modifier.fillMaxWidth())
        LabelColorPicker(labelColor, onSelected = { labelColor = it }, enabled = !state.working)
        Button(
            onClick = {
                val previousColor = labelColor
                model.createBoardLabel(labelName, labelColor)
                labelName = ""
                labelColor = randomLabelColor(previousColor)
            },
            enabled = labelName.isNotBlank() && !state.working,
            modifier = Modifier.padding(top = 8.dp),
        ) { Text("Add label") }
    }
    HorizontalDivider(Modifier.padding(vertical = 14.dp))
    SectionTitle("Create board")
    OutlinedTextField(newBoardName, { newBoardName = it }, label = { Text("Board name") }, modifier = Modifier.fillMaxWidth())
    OutlinedTextField(description, { description = it }, label = { Text("Description") }, modifier = Modifier.fillMaxWidth())
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        FilterChip(selected = workflow == "review", onClick = { workflow = "review" }, label = { Text("Review") })
        FilterChip(selected = workflow == "direct", onClick = { workflow = "direct" }, label = { Text("Direct") })
    }
    Button(
        onClick = { model.createBoard(newBoardName, workflow, description); newBoardName = "" },
        enabled = newBoardName.isNotBlank() && state.selectedProjectId.isNotBlank() && !state.working,
    ) { Text("Create board") }
}

@Composable
private fun LabelColorPicker(selectedColor: String, onSelected: (String) -> Unit, enabled: Boolean) {
    val selected = LabelColorPalette.firstOrNull { it.value.equals(selectedColor, ignoreCase = true) }
        ?: LabelColorPalette.first()
    Column(
        Modifier.padding(top = 10.dp).widthIn(max = 340.dp),
        verticalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("Color", fontWeight = FontWeight.Medium)
            Text(selected.name, color = DieterMuted, fontSize = 12.sp)
        }
        LabelColorPalette.chunked(5).forEach { colors ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                colors.forEach { option ->
                    val color = Color(option.value.toColorInt())
                    val isSelected = option.value.equals(selected.value, ignoreCase = true)
                    Box(
                        Modifier.size(46.dp)
                            .clip(CircleShape)
                            .selectable(
                                selected = isSelected,
                                enabled = enabled,
                                onClick = { onSelected(option.value) },
                            )
                            .semantics { contentDescription = "${option.name} label color" }
                            .border(
                                width = if (isSelected) 2.dp else 1.dp,
                                color = if (isSelected) DieterShell else DieterOutline,
                                shape = CircleShape,
                            )
                            .padding(4.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Box(Modifier.fillMaxSize().clip(CircleShape).background(color))
                        if (isSelected) {
                            androidx.compose.material3.Icon(
                                Icons.Default.Check,
                                contentDescription = null,
                                tint = if (color.luminance() > 0.32f) DieterAbyss else Color.White,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ManagementLabelPill(name: String, colorValue: String) {
    val color = runCatching { Color(colorValue.toColorInt()) }.getOrDefault(DieterShell)
    Surface(shape = RoundedCornerShape(50), color = color.copy(alpha = 0.16f)) {
        Row(
            Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
            horizontalArrangement = Arrangement.spacedBy(7.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.size(7.dp).clip(CircleShape).background(color))
            Text(name, color = color, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun LimitsManagement(state: DieterUiState, model: DieterViewModel) {
    val current = state.settings
    val options = state.settingsOptions
    var global by remember(current?.updatedAt) { mutableStateOf((current?.globalParallelLimit ?: 0).toString()) }
    var agentLimits by remember(current?.updatedAt, options) {
        mutableStateOf(current?.agentParallelLimitsMap.orEmpty().mapValues { it.value.toString() })
    }
    var boardLimits by remember(current?.updatedAt, options) {
        mutableStateOf(current?.boardParallelLimitsMap.orEmpty().mapValues { it.value.toString() })
    }
    SectionTitle("Admission limits")
    Text("All HTTP, CLI, Android, and scheduled starts share these limits.", color = DieterMuted)
    OutlinedTextField(
        global,
        { global = it.filter(Char::isDigit) },
        label = { Text("Global parallel sessions") },
        modifier = Modifier.fillMaxWidth(),
    )
    SectionTitle("Per agent")
    options?.agents?.harnessesList.orEmpty().forEach { harness ->
        OutlinedTextField(
            value = agentLimits[harness.id] ?: "0",
            onValueChange = { value -> agentLimits = agentLimits + (harness.id to value.filter(Char::isDigit)) },
            label = { Text("${harness.name} sessions") },
            supportingText = { Text(harness.id) },
            modifier = Modifier.fillMaxWidth(),
        )
    }
    SectionTitle("Per board")
    options?.boardsList.orEmpty().forEach { board ->
        val project = options?.projectsList?.firstOrNull { it.id == board.projectId }?.name.orEmpty()
        OutlinedTextField(
            value = boardLimits[board.id] ?: "0",
            onValueChange = { value -> boardLimits = boardLimits + (board.id to value.filter(Char::isDigit)) },
            label = { Text("${board.name} sessions") },
            supportingText = { if (project.isNotBlank()) Text(project) },
            modifier = Modifier.fillMaxWidth(),
        )
    }
    Button(
        onClick = {
            val value = global.toIntOrNull() ?: return@Button
            val updated = (current ?: Settings.getDefaultInstance()).toBuilder()
                .setGlobalParallelLimit(value)
                .clearAgentParallelLimits()
                .putAllAgentParallelLimits(agentLimits.mapValues { it.value.toIntOrNull() ?: 0 })
                .clearBoardParallelLimits()
                .putAllBoardParallelLimits(boardLimits.mapValues { it.value.toIntOrNull() ?: 0 })
                .build()
            model.updateSettings(updated)
        },
        enabled = global.toIntOrNull() != null && !state.working,
        modifier = Modifier.padding(top = 8.dp),
    ) { Text("Save limits") }
    Text("Use 0 for no override.", color = DieterMuted, style = MaterialTheme.typography.bodySmall)
}

@Composable
private fun ArchivesManagement(state: DieterUiState, model: DieterViewModel) {
    SectionTitle("Archived projects")
    if (state.archivedProjects.isEmpty()) Text("No archived projects", color = DieterMuted)
    state.archivedProjects.forEach { project ->
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(project.name, Modifier.weight(1f))
            TextButton(onClick = { model.restoreProject(project) }) { Text("Restore") }
        }
    }
    SectionTitle("Archived cards")
    if (state.archivedCards.isEmpty()) Text("No archived cards in this board", color = DieterMuted)
    state.archivedCards.forEach { card ->
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(card.title, Modifier.weight(1f))
            TextButton(onClick = { model.restoreCard(card) }) { Text("Restore") }
        }
    }
}

internal fun EndpointConnection.usableForProjectCreation(): Boolean = online &&
    daemonId != null && (apiVersion.isBlank() || apiVersion == DIETER_API_VERSION)

@Composable
internal fun ProjectHostPicker(
    machines: List<EndpointConnection>,
    selectedId: String,
    onSelected: (String) -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    val selected = machines.firstOrNull { it.id == selectedId }
    Box(Modifier.fillMaxWidth()) {
        OutlinedButton(
            onClick = { menuOpen = true },
            modifier = Modifier.fillMaxWidth().height(56.dp).testTag("new-project-machine"),
        ) {
            Column(Modifier.weight(1f), horizontalAlignment = Alignment.Start) {
                Text(selected?.label ?: "Choose a project host", fontWeight = FontWeight.SemiBold)
                Text(
                    when {
                        selected == null -> "No machine selected"
                        !selected.online -> "Offline"
                        selected.apiVersion.isNotBlank() && selected.apiVersion != DIETER_API_VERSION ->
                            "Requires API $DIETER_API_VERSION"
                        else -> "Online · repository and agents run here"
                    },
                    color = DieterMuted,
                    fontSize = 11.sp,
                )
            }
            Text("⌄", color = DieterMuted)
        }
        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            machines.forEach { machine ->
                DropdownMenuItem(
                    text = {
                        Column {
                            Text(machine.label)
                            Text(
                                when {
                                    !machine.online -> "Offline"
                                    machine.apiVersion.isNotBlank() && machine.apiVersion != DIETER_API_VERSION ->
                                        "Incompatible API ${machine.apiVersion}"
                                    else -> machine.detail
                                },
                                color = DieterMuted,
                                fontSize = 11.sp,
                            )
                        }
                    },
                    enabled = machine.usableForProjectCreation(),
                    modifier = Modifier.testTag("new-project-machine-${machine.id}"),
                    onClick = { menuOpen = false; onSelected(machine.id) },
                )
            }
        }
    }
}

@Composable
private fun AddProjectManagement(state: DieterUiState, model: DieterViewModel) {
    var mode by remember { mutableStateOf("open") }
    var path by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    var summary by remember { mutableStateOf("") }
    var prompt by remember { mutableStateOf("") }
    var boardName by remember { mutableStateOf("Main") }
    var workflow by remember { mutableStateOf("review") }
    var baseRemote by remember { mutableStateOf("origin") }
    var baseBranch by remember { mutableStateOf("main") }
    var remotePublishMode by remember { mutableStateOf("manual") }
    var validationCommands by remember { mutableStateOf(emptyList<ValidationCommandDraft>()) }
    var endpointId by remember { mutableStateOf("") }
    var workflowOpen by remember { mutableStateOf(false) }
    var showBrowser by remember { mutableStateOf(false) }
    val machines = state.presentedEndpointConnections.filter { it.daemonId != null }
    val selectedMachine = machines.firstOrNull { it.id == endpointId }
    val listing = state.directoryListing.takeIf { state.directoryListingEndpointId == endpointId }
    LaunchedEffect(machines, endpointId) {
        if (machines.none { it.id == endpointId && it.usableForProjectCreation() }) {
            endpointId = machines.firstOrNull {
                it.phase == EndpointPhase.CONNECTED && it.usableForProjectCreation()
            }?.id ?: machines.firstOrNull { it.usableForProjectCreation() }?.id.orEmpty()
        }
    }
    LaunchedEffect(showBrowser, listing?.path) {
        if (!showBrowser) return@LaunchedEffect
        listing?.path?.takeIf { it.isNotBlank() }?.let { path = it }
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        FilterChip(
            selected = mode == "open",
            onClick = { mode = "open" },
            label = { Text("✓  Existing Git repo") },
            modifier = Modifier.weight(1f).testTag("new-project-mode-open"),
        )
        FilterChip(
            selected = mode == "create",
            onClick = { mode = "create" },
            label = { Text("New Git project") },
            modifier = Modifier.weight(1f).testTag("new-project-mode-create"),
        )
    }
    Spacer(Modifier.height(10.dp))
    Text("Project host", color = DieterMuted, style = MaterialTheme.typography.labelMedium)
    ProjectHostPicker(machines, endpointId) { selectedId ->
        endpointId = selectedId
        path = ""
        showBrowser = false
        model.clearDirectoryListing()
    }
    Text(
        "The repository path and every agent process belong to this host.",
        color = DieterMuted,
        style = MaterialTheme.typography.bodySmall,
    )
    Spacer(Modifier.height(10.dp))
    Text(if (mode == "create") "New project path" else "Git working tree", color = DieterMuted, style = MaterialTheme.typography.labelMedium)
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(
            path,
            { path = it },
            placeholder = { Text("/Users/you/Development/project") },
            singleLine = true,
            modifier = Modifier.weight(1f).testTag("new-project-path"),
        )
        OutlinedButton(
            onClick = { showBrowser = true; model.listDirectories(endpointId, path) },
            enabled = selectedMachine?.usableForProjectCreation() == true && !state.directoryListingLoading,
            modifier = Modifier.height(56.dp),
        ) { Text("Browse") }
    }
    if (showBrowser) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 8.dp)) {
            listing?.parent?.takeIf { it.isNotBlank() }?.let { parent ->
                OutlinedButton(onClick = { path = parent; model.listDirectories(endpointId, parent) }) { Text("Parent") }
            }
            TextButton(onClick = { showBrowser = false }) { Text("Close browser") }
            if (state.directoryListingLoading) CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp)
        }
        if ((listing?.locationsCount ?: 0) > 0) {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                listing?.locationsList.orEmpty().forEach { location ->
                    FilterChip(
                        selected = path == location.path,
                        onClick = { path = location.path; model.listDirectories(endpointId, location.path) },
                        label = { Text(location.name) },
                    )
                }
            }
        }
        listing?.entriesList.orEmpty().filterNot { it.name.startsWith('.') }.take(20).forEach { entry ->
            TextButton(onClick = { path = entry.path; model.listDirectories(endpointId, entry.path) }, modifier = Modifier.fillMaxWidth()) {
                Text("${if (entry.gitRepository) "Git · " else ""}${entry.name}", modifier = Modifier.fillMaxWidth())
            }
        }
    }
    Spacer(Modifier.height(10.dp))
    OutlinedTextField(name, { name = it }, label = { Text("Project name") }, modifier = Modifier.fillMaxWidth().testTag("new-project-name"))
    Text("Optional; the directory name is used by default.", color = DieterMuted, style = MaterialTheme.typography.bodySmall)
    OutlinedTextField(summary, { summary = it }, label = { Text("Summary") }, modifier = Modifier.fillMaxWidth().testTag("new-project-summary"))
    Spacer(Modifier.height(14.dp))
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        OutlinedTextField(boardName, { boardName = it }, label = { Text("First board") }, modifier = Modifier.weight(1f).testTag("new-project-board"))
        Box(Modifier.weight(1f)) {
            OutlinedButton(onClick = { workflowOpen = true }, modifier = Modifier.fillMaxWidth().height(56.dp)) {
                Text(if (workflow == "review") "With review" else "Direct workflow")
            }
            DropdownMenu(expanded = workflowOpen, onDismissRequest = { workflowOpen = false }) {
                DropdownMenuItem(text = { Text("With review") }, onClick = { workflow = "review"; workflowOpen = false })
                DropdownMenuItem(text = { Text("Direct workflow") }, onClick = { workflow = "direct"; workflowOpen = false })
            }
        }
    }
    Spacer(Modifier.height(8.dp))
    SectionTitle("Agent workspaces")
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(
            baseRemote,
            { baseRemote = it },
            label = { Text("Base remote") },
            singleLine = true,
            modifier = Modifier.weight(1f).testTag("new-project-base-remote"),
        )
        OutlinedTextField(
            baseBranch,
            { baseBranch = it },
            label = { Text("Base branch") },
            singleLine = true,
            modifier = Modifier.weight(1f).testTag("new-project-base-branch"),
        )
    }
    Text("First-board publishing", color = DieterMuted, modifier = Modifier.padding(top = 6.dp))
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        listOf("manual" to "Manual", "pull_request" to "Pull request", "push_base" to "Push base").forEach { option ->
            FilterChip(
                selected = remotePublishMode == option.first,
                onClick = { remotePublishMode = option.first },
                label = { Text(option.second) },
            )
        }
    }
    SectionTitle("Validation commands")
    ValidationCommandsEditor(validationCommands, onChange = { validationCommands = it }, enabled = !state.working)
    val validationError = validationCommandsError(validationCommands)
    validationError?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
    Spacer(Modifier.height(8.dp))
    OutlinedTextField(
        prompt,
        { prompt = it },
        label = { Text("Project instructions") },
        placeholder = { Text("How should agents work in this project?") },
        minLines = 7,
        modifier = Modifier.fillMaxWidth().testTag("new-project-instructions"),
    )
    Text("Stored centrally and included in every new card conversation.", color = DieterMuted, style = MaterialTheme.typography.bodySmall)
    Row(Modifier.fillMaxWidth().padding(top = 18.dp), horizontalArrangement = Arrangement.End) {
        TextButton(onClick = { model.openSurface(AppSurface.WORKSPACE) }) { Text("Cancel") }
        Button(
            onClick = {
                model.createProject(
                    endpointId = endpointId,
                    mode = mode,
                    path = path,
                    name = name,
                    summary = summary,
                    prompt = prompt,
                    boardName = boardName,
                    workflow = workflow,
                    baseRemote = baseRemote,
                    baseBranch = baseBranch,
                    validationCommands = validationCommands.map(ValidationCommandDraft::value),
                    remotePublishMode = remotePublishMode,
                )
            },
            enabled = selectedMachine?.usableForProjectCreation() == true && path.isNotBlank() && boardName.isNotBlank() &&
                baseBranch.isNotBlank() && validationError == null && !state.working,
            modifier = Modifier.testTag("new-project-submit"),
        ) { Text("＋  Add project") }
    }
}

@Composable
private fun SectionTitle(value: String) {
    Text(value, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(vertical = 8.dp))
}
