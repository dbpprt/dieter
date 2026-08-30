@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import android.app.TimePickerDialog
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.automirrored.outlined.List
import androidx.compose.material.icons.outlined.AccountTree
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material.icons.outlined.AttachFile
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.CreditCard
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.ViewKanban
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterOutline
import com.dbpprt.dieter.ui.theme.DieterSurface
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh
import com.dbpprt.dieter.ui.theme.DieterText
import com.dbpprt.dieter.v1.Harness
import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.Schedule
import com.dbpprt.dieter.v1.ScheduleDraft
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import com.dbpprt.dieter.ui.theme.DieterAbyss

@Composable
fun NewConversationScreen(
    state: DieterUiState,
    model: DieterViewModel,
    chat: Boolean,
    contentPadding: PaddingValues,
) {
    var title by remember { mutableStateOf("") }
    var prompt by remember { mutableStateOf("") }
    var provider by remember(state.harnesses) { mutableStateOf(state.harnesses.firstOrNull()?.id.orEmpty()) }
    val harness = state.harnesses.firstOrNull { it.id == provider } ?: state.harnesses.firstOrNull()
    var selectedModel by remember(provider, harness) { mutableStateOf(harness?.defaultModel.orEmpty()) }
    var effort by remember(provider, selectedModel) { mutableStateOf("") }
    var providerOptions by remember(provider, harness) { mutableStateOf(providerOptionValues(harness)) }
    var lane by remember(state.selectedLane) {
        mutableStateOf(state.selectedLane.ifBlank { state.board?.lanesList?.firstOrNull()?.id.orEmpty() })
    }
    var workspaceMode by remember { mutableStateOf(ConversationWorkspaceMode.WORKTREE) }
    val labelIds = remember { mutableStateListOf<String>() }
    val attachments = remember { mutableStateListOf<MessagePart>() }
    var attachmentPickerVisible by remember { mutableStateOf(false) }
    var attachmentError by remember { mutableStateOf<String?>(null) }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    fun addPickedAttachments(uris: List<android.net.Uri>, imagesOnly: Boolean) {
        if (uris.isEmpty()) return
        scope.launch {
            attachmentError = null
            val results = withContext(Dispatchers.IO) {
                uris.map { uri -> runCatching { readAttachmentPart(context, uri, imagesOnly) } }
            }
            val incoming = results.mapNotNull(Result<MessagePart>::getOrNull)
            val limitError = attachmentLimitError(attachments, incoming)
            if (limitError == null) attachments += incoming
            attachmentError = limitError ?: results.firstNotNullOfOrNull { it.exceptionOrNull()?.message }
        }
    }
    val imagePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia(MAX_COMPOSER_ATTACHMENTS),
    ) { uris -> addPickedAttachments(uris, imagesOnly = true) }
    val filePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments(),
    ) { uris -> addPickedAttachments(uris, imagesOnly = false) }
    val canSubmit = canCreateConversation(
        projectId = state.project?.id.orEmpty(),
        provider = provider,
        model = selectedModel,
        prompt = prompt,
        chat = chat,
        title = title,
        hasAttachments = attachments.isNotEmpty(),
    )

    Column(Modifier.fillMaxSize().padding(contentPadding)) {
        CreationHeader(
            eyebrow = if (chat) null else state.board?.name ?: "Board",
            title = if (chat) "New chat" else "New card",
            subtitle = if (chat) "${state.project?.name ?: "Project"} · Standalone chat" else state.project?.name,
            onClose = model::closeSurface,
            trailing = if (chat) {
                { NeutralPill("New") }
            } else {
                {
                    Button(
                        onClick = {
                            val cleanTitle = title.trim()
                            val cleanPrompt = prompt.trim()
                            model.createConversation(
                                title = cleanTitle,
                                prompt = cleanPrompt.ifBlank { cleanTitle },
                                chat = false,
                                provider = provider,
                                model = selectedModel,
                                effort = effort,
                                providerOptions = providerOptions,
                                lane = lane,
                                labelIds = labelIds.toList(),
                                deferStart = shouldDeferConversationStart(chat = false, lane = lane),
                                attachments = attachments.toList(),
                                workspaceMode = workspaceMode.wire,
                            )
                        },
                        enabled = canSubmit && !state.working,
                    ) { Text(if (lane == "running") "Create & run" else "Save") }
                }
            },
        )
        SurfaceErrorBanner(state.error, model::clearError)
        attachmentError?.let { message ->
            Text(
                message,
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
            )
        }
        if (chat) {
            NewChatBody(
                prompt = prompt,
                onPromptChange = { prompt = it },
                state = state,
                onProjectChange = model::selectProject,
                provider = provider,
                onProviderChange = { next -> provider = next; selectedModel = state.harnesses.firstOrNull { it.id == next }?.defaultModel.orEmpty(); effort = "" },
                harness = harness,
                model = selectedModel,
                onModelChange = { selectedModel = it; effort = "" },
                effort = effort,
                onEffortChange = { effort = it },
                providerOptions = providerOptions,
                onProviderOptionChange = { id, value -> providerOptions = providerOptions + (id to value) },
                canSubmit = canSubmit && !state.working,
                workspaceMode = workspaceMode,
                onWorkspaceModeChange = { workspaceMode = it },
                attachments = attachments,
                onAttach = { attachmentPickerVisible = true },
                onRemoveAttachment = { attachments.removeAt(it) },
                onSubmit = {
                    val cleanPrompt = prompt.trim()
                    model.createConversation(
                        title = titleFromPrompt(cleanPrompt),
                        prompt = cleanPrompt,
                        chat = true,
                        provider = provider,
                        model = selectedModel,
                        effort = effort,
                        providerOptions = providerOptions,
                        lane = "",
                        labelIds = emptyList(),
                        deferStart = shouldDeferConversationStart(chat = true, lane = ""),
                        attachments = attachments.toList(),
                        workspaceMode = workspaceMode.wire,
                    )
                },
            )
        } else {
            NewCardBody(
                state = state,
                title = title,
                onTitleChange = { title = it },
                prompt = prompt,
                onPromptChange = { prompt = it },
                provider = provider,
                onProviderChange = { next -> provider = next; selectedModel = state.harnesses.firstOrNull { it.id == next }?.defaultModel.orEmpty(); effort = "" },
                harness = harness,
                model = selectedModel,
                onModelChange = { selectedModel = it; effort = "" },
                effort = effort,
                onEffortChange = { effort = it },
                providerOptions = providerOptions,
                onProviderOptionChange = { id, value -> providerOptions = providerOptions + (id to value) },
                lane = lane,
                onLaneChange = { lane = it },
                labelIds = labelIds,
                workspaceMode = workspaceMode,
                onWorkspaceModeChange = { workspaceMode = it },
                attachments = attachments,
                onAttach = { attachmentPickerVisible = true },
                onRemoveAttachment = { attachments.removeAt(it) },
            )
        }
    }
    if (attachmentPickerVisible) {
        AttachmentPickerSheet(
            onDismiss = { attachmentPickerVisible = false },
            onImages = {
                attachmentPickerVisible = false
                imagePicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
            },
            onFiles = {
                attachmentPickerVisible = false
                filePicker.launch(arrayOf("*/*"))
            },
        )
    }
}

@Composable
private fun NewChatBody(
    prompt: String,
    onPromptChange: (String) -> Unit,
    state: DieterUiState,
    onProjectChange: (String) -> Unit,
    provider: String,
    onProviderChange: (String) -> Unit,
    harness: Harness?,
    model: String,
    onModelChange: (String) -> Unit,
    effort: String,
    onEffortChange: (String) -> Unit,
    providerOptions: Map<String, String>,
    onProviderOptionChange: (String, String) -> Unit,
    canSubmit: Boolean,
    workspaceMode: ConversationWorkspaceMode,
    onWorkspaceModeChange: (ConversationWorkspaceMode) -> Unit,
    attachments: List<MessagePart>,
    onAttach: () -> Unit,
    onRemoveAttachment: (Int) -> Unit,
    onSubmit: () -> Unit,
) {
    val suggestions = listOf(
        Icons.Outlined.Search to "Explain how this codebase works",
        Icons.Outlined.Edit to "Fix a failing test",
        Icons.AutoMirrored.Outlined.List to "Summarize recent changes",
    )
    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 12.dp)) {
        Column(
            modifier = Modifier.weight(1f).fillMaxWidth(),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Surface(shape = RoundedCornerShape(18.dp), color = DieterSurfaceHigh, modifier = Modifier.size(64.dp)) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(Icons.Outlined.ChatBubbleOutline, null, tint = DieterShell, modifier = Modifier.size(28.dp))
                }
            }
            Spacer(Modifier.height(18.dp))
            Text("Chat with your local agent", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(10.dp))
            Text(
                "Runs on your machine with full access to this project's files. Ask questions, make changes, or explore the code.",
                color = DieterMuted,
                style = MaterialTheme.typography.bodyMedium,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(0.88f),
            )
            Spacer(Modifier.height(16.dp))
            Column(
                Modifier.fillMaxWidth(0.92f),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                suggestions.forEach { (icon, text) ->
                    TextButton(
                        onClick = { onPromptChange(text) },
                        modifier = Modifier.fillMaxWidth().border(1.dp, DieterOutline, RoundedCornerShape(14.dp)),
                        shape = RoundedCornerShape(14.dp),
                        colors = ButtonDefaults.textButtonColors(contentColor = DieterText),
                    ) {
                        Icon(icon, null, tint = DieterShell, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.size(10.dp))
                        Text(text, modifier = Modifier.weight(1f))
                    }
                }
            }
        }
        SelectorField(
            label = "Project",
            value = state.project?.let { project ->
                state.presentedProjectHosts[project.id]?.hostname
                    ?.takeIf(String::isNotBlank)
                    ?.let { host -> "${project.name} · $host" }
                    ?: project.name
            } ?: "Select a project",
            options = chatProjectOptions(state.projects, state.presentedProjectHosts),
            onSelect = onProjectChange,
            modifier = Modifier.fillMaxWidth().testTag("chat-project-selector"),
        )
        Spacer(Modifier.height(8.dp))
        ModelSelectors(
            state, provider, onProviderChange, harness, model, onModelChange, effort, onEffortChange,
            providerOptions, onProviderOptionChange,
        )
        Spacer(Modifier.height(8.dp))
        WorkspaceModeChips(workspaceMode, onWorkspaceModeChange)
        Spacer(Modifier.height(8.dp))
        if (attachments.isNotEmpty()) {
            Row(
                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                attachments.forEachIndexed { index, part ->
                    ComposerAttachmentPreview(part, index, enabled = true) { onRemoveAttachment(index) }
                }
            }
            Spacer(Modifier.height(8.dp))
        }
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            IconButton(
                onClick = onAttach,
                modifier = Modifier.size(48.dp).testTag("create-attach"),
            ) { Icon(Icons.Outlined.AttachFile, "Attach images or files") }
            TextField(
                value = prompt,
                onValueChange = onPromptChange,
                placeholder = { Text("Message the local agent…") },
                minLines = 1,
                maxLines = 4,
                shape = RoundedCornerShape(26.dp),
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = DieterSurface,
                    unfocusedContainerColor = DieterSurface,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                ),
                modifier = Modifier.weight(1f).testTag("conversation-prompt"),
            )
            FloatingActionButton(
                onClick = { if (canSubmit) onSubmit() },
                modifier = Modifier.size(52.dp).testTag("create-chat"),
                containerColor = DieterShell,
                contentColor = DieterAbyss,
            ) { Icon(Icons.AutoMirrored.Filled.Send, "Start chat") }
        }
    }
}

@Composable
private fun NewCardBody(
    state: DieterUiState,
    title: String,
    onTitleChange: (String) -> Unit,
    prompt: String,
    onPromptChange: (String) -> Unit,
    provider: String,
    onProviderChange: (String) -> Unit,
    harness: Harness?,
    model: String,
    onModelChange: (String) -> Unit,
    effort: String,
    onEffortChange: (String) -> Unit,
    providerOptions: Map<String, String>,
    onProviderOptionChange: (String, String) -> Unit,
    lane: String,
    onLaneChange: (String) -> Unit,
    labelIds: MutableList<String>,
    workspaceMode: ConversationWorkspaceMode,
    onWorkspaceModeChange: (ConversationWorkspaceMode) -> Unit,
    attachments: List<MessagePart>,
    onAttach: () -> Unit,
    onRemoveAttachment: (Int) -> Unit,
) {
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        OutlinedTextField(title, onTitleChange, label = { Text("Card title") }, singleLine = true, modifier = Modifier.fillMaxWidth().testTag("conversation-title"))
        OutlinedTextField(prompt, onPromptChange, label = { Text("Agent task") }, minLines = 6, modifier = Modifier.fillMaxWidth().testTag("conversation-prompt"))
        FormSection(Icons.Outlined.AttachFile, "Attachments") {
            TextButton(onClick = onAttach, modifier = Modifier.testTag("create-attach")) {
                Icon(Icons.Outlined.AttachFile, null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.size(8.dp))
                Text("Add images or files")
            }
            if (attachments.isNotEmpty()) {
                Row(
                    Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    attachments.forEachIndexed { index, part ->
                        ComposerAttachmentPreview(part, index, enabled = true) { onRemoveAttachment(index) }
                    }
                }
            }
            Text("Up to 4 attachments · 5 MB each · 6 MB total", color = DieterMuted, fontSize = 11.sp)
        }
        FormSection(Icons.Outlined.ViewKanban, "Start in") {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                state.board?.lanesList.orEmpty().filter { it.id == "todo" || it.id == "running" }.forEach { boardLane ->
                    FilterChip(selected = lane == boardLane.id, onClick = { onLaneChange(boardLane.id) }, label = { Text(boardLane.name) })
                }
            }
        }
        if ((state.board?.labelsCount ?: 0) > 0) {
            FormSection(Icons.Outlined.CreditCard, "Labels") {
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    state.board?.labelsList.orEmpty().forEach { label ->
                        FilterChip(
                            selected = label.id in labelIds,
                            onClick = { if (label.id in labelIds) labelIds.remove(label.id) else labelIds += label.id },
                            label = { Text(label.name) },
                        )
                    }
                }
            }
        }
        FormSection(Icons.Outlined.AccountTree, "Workspace") {
            WorkspaceModeChips(workspaceMode, onWorkspaceModeChange)
            Text(workspaceMode.detail, color = DieterMuted, style = MaterialTheme.typography.bodySmall)
        }
        FormSection(Icons.Outlined.Bolt, "Agent") {
            ModelSelectors(
                state, provider, onProviderChange, harness, model, onModelChange, effort, onEffortChange,
                providerOptions, onProviderOptionChange,
            )
        }
        Text(
            if (lane == "running") "The first message starts immediately." else "The card is saved as a draft in Todo.",
            color = DieterMuted,
            style = MaterialTheme.typography.bodySmall,
        )
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun WorkspaceModeChips(
    selected: ConversationWorkspaceMode,
    onSelect: (ConversationWorkspaceMode) -> Unit,
) {
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        ConversationWorkspaceMode.entries.forEach { mode ->
            FilterChip(
                selected = selected == mode,
                onClick = { onSelect(mode) },
                label = { Text(if (mode == ConversationWorkspaceMode.WORKTREE) "New worktree" else "Project directory") },
                modifier = Modifier.testTag("workspace-mode-${mode.wire}"),
            )
        }
    }
}

@Composable
fun NewBoardScreen(state: DieterUiState, model: DieterViewModel, contentPadding: PaddingValues) {
    var name by remember { mutableStateOf("") }
    var description by remember { mutableStateOf("") }
    var workflow by remember { mutableStateOf("review") }
    val canCreate = name.isNotBlank() && state.selectedProjectId.isNotBlank() && !state.working

    Column(Modifier.fillMaxSize().padding(contentPadding)) {
        CreationHeader(
            eyebrow = state.project?.name ?: "Project",
            title = "New board",
            subtitle = compactBoardPath(state.project?.path.orEmpty()),
            onClose = model::closeSurface,
            trailing = {
                Button(
                    onClick = { model.createBoard(name.trim(), workflow, description.trim(), openAfterCreate = true) },
                    enabled = canCreate,
                    modifier = Modifier.testTag("create-board"),
                ) { Text("Create") }
            },
        )
        SurfaceErrorBanner(state.error, model::clearError)
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 18.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("Board name") },
                placeholder = { Text("Product delivery") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().testTag("board-name"),
            )
            OutlinedTextField(
                value = description,
                onValueChange = { description = it },
                label = { Text("Description") },
                placeholder = { Text("What work belongs on this board?") },
                minLines = 3,
                modifier = Modifier.fillMaxWidth(),
            )
            FormSection(Icons.Outlined.ViewKanban, "Workflow") {
                FilterChip(
                    selected = workflow == "review",
                    onClick = { workflow = "review" },
                    label = { Text("Todo → Running → Review → Done") },
                    modifier = Modifier.fillMaxWidth(),
                )
                FilterChip(
                    selected = workflow == "direct",
                    onClick = { workflow = "direct" },
                    label = { Text("Todo → Running → Done") },
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    if (workflow == "review") "Review keeps completed agent work waiting for your approval."
                    else "Direct moves completed work straight to Done.",
                    color = DieterMuted,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            Text("Completed conversations are kept until you change this board's retention setting.", color = DieterMuted, fontSize = 12.sp)
        }
    }
}

private fun compactBoardPath(path: String): String {
    val marker = "/Development/"
    return if (marker in path) "~$marker${path.substringAfter(marker)}" else path
}

@Composable
fun ScheduleEditorScreen(
    state: DieterUiState,
    model: DieterViewModel,
    schedule: Schedule?,
    contentPadding: PaddingValues,
) {
    var name by remember(schedule?.id) { mutableStateOf(schedule?.name.orEmpty()) }
    var description by remember(schedule?.id) { mutableStateOf(schedule?.description.orEmpty()) }
    var customCron by remember(schedule?.id) { mutableStateOf(schedule?.cron ?: "0 9 * * 1-5") }
    var repeat by remember(schedule?.id) { mutableStateOf(scheduleRepeat(schedule?.cron)) }
    var runAt by remember(schedule?.id) { mutableStateOf(scheduleTime(schedule?.cron)) }
    var weeklyDay by remember(schedule?.id) { mutableStateOf(scheduleWeekday(schedule?.cron)) }
    var timezone by remember(schedule?.id) { mutableStateOf(schedule?.timezone ?: ZoneId.systemDefault().id) }
    var prompt by remember(schedule?.id) { mutableStateOf(schedule?.promptTemplate.orEmpty()) }
    var titleTemplate by remember(schedule?.id) { mutableStateOf(schedule?.titleTemplate ?: "Scheduled work · {{date}}") }
    var action by remember(schedule?.id) { mutableStateOf(schedule?.action ?: "draft") }
    var enabled by remember(schedule?.id) { mutableStateOf(schedule?.enabled ?: true) }
    var boardId by remember(schedule?.id) { mutableStateOf(schedule?.boardId ?: state.selectedBoardId) }
    var provider by remember(schedule?.id, state.harnesses) { mutableStateOf(schedule?.provider ?: state.harnesses.firstOrNull()?.id.orEmpty()) }
    val harness = state.harnesses.firstOrNull { it.id == provider } ?: state.harnesses.firstOrNull()
    var selectedModel by remember(schedule?.id, provider, harness) { mutableStateOf(schedule?.model?.ifBlank { null } ?: harness?.defaultModel.orEmpty()) }
    var effort by remember(schedule?.id, provider, selectedModel) { mutableStateOf(schedule?.effort.orEmpty()) }
    var providerOptions by remember(schedule?.id, provider, harness) {
        mutableStateOf(
            providerOptionValues(
                harness,
                schedule?.providerOptionsMap?.takeIf { schedule.provider == provider }.orEmpty(),
            ),
        )
    }
    val labelIds = remember(schedule?.id) { mutableStateListOf<String>().also { it += schedule?.labelIdsList.orEmpty() } }
    var openPolicy by remember(schedule?.id) { mutableStateOf(schedule?.openCardPolicy ?: "skip_if_open") }
    var busyPolicy by remember(schedule?.id) { mutableStateOf(schedule?.busyPolicy ?: "queue") }
    var workspaceMode by remember(schedule?.id) {
        mutableStateOf(schedule?.let { ConversationWorkspaceMode.resolve(it.workspaceMode) } ?: ConversationWorkspaceMode.WORKTREE)
    }
    val cron = scheduleCron(repeat, runAt, weeklyDay, customCron)
    val canSave = name.isNotBlank() && cron.isNotBlank() && timezone.isNotBlank() && titleTemplate.isNotBlank() &&
        prompt.isNotBlank() && provider.isNotBlank() && boardId.isNotBlank()

    LaunchedEffect(cron, timezone) {
        delay(350)
        if (cron.isNotBlank() && timezone.isNotBlank()) model.previewSchedule(cron, timezone)
    }

    fun save() {
        model.saveSchedule(
            schedule?.id.orEmpty(),
            ScheduleDraft.newBuilder()
                .setProjectId(state.selectedProjectId)
                .setBoardId(boardId)
                .setName(name.trim())
                .setDescription(description.trim())
                .setCron(cron.trim())
                .setTimezone(timezone.trim())
                .setEnabled(enabled)
                .setAction(action)
                .setTitleTemplate(titleTemplate.trim())
                .setPromptTemplate(prompt.trim())
                .setProvider(provider)
                .setModel(selectedModel)
                .setEffort(effort)
                .putAllProviderOptions(providerOptions)
                .setOpenCardPolicy(openPolicy)
                .setMisfirePolicy("latest")
                .setBusyPolicy(busyPolicy)
                .setWorkspaceMode(workspaceMode.wire)
                .addAllLabelIds(labelIds)
                .build(),
        )
    }

    Column(Modifier.fillMaxSize().padding(contentPadding)) {
        CreationHeader(
            eyebrow = if (schedule == null) "New automation" else "Edit automation",
            title = if (schedule == null) "New schedule" else "Edit schedule",
            subtitle = "Runs on the project daemon · $timezone",
            onClose = model::closeSurface,
            trailing = {
                Button(onClick = ::save, enabled = canSave && !state.working) {
                    Text("Save")
                }
            },
        )
        SurfaceErrorBanner(state.error, model::clearError)
        Column(
            Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            OutlinedTextField(
                name,
                { name = it },
                label = { Text("Schedule name") },
                placeholder = { Text("Morning project check") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().testTag("schedule-name"),
            )
            OutlinedTextField(
                description,
                { description = it },
                label = { Text("Description") },
                placeholder = { Text("What this automation is responsible for") },
                minLines = 2,
                modifier = Modifier.fillMaxWidth(),
            )
            FormSection(Icons.Outlined.Schedule, "Timing", trailing = { Text(scheduleTimingSummary(repeat, runAt, weeklyDay), color = DieterMuted, fontSize = 11.sp) }) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    SelectorField(
                        label = "Repeats",
                        value = repeat,
                        options = listOf("Weekdays", "Daily", "Weekly", "Custom").map { it to it },
                        onSelect = { repeat = it },
                        modifier = Modifier.weight(1f),
                    )
                    if (repeat == "Weekly") {
                        SelectorField(
                            label = "Day",
                            value = scheduleWeekdays.firstOrNull { it.first == weeklyDay }?.second ?: "Monday",
                            options = scheduleWeekdays,
                            onSelect = { weeklyDay = it },
                            modifier = Modifier.weight(1f).testTag("schedule-weekday"),
                        )
                    }
                }
                if (repeat != "Custom") {
                    ScheduleTimeField(runAt, { runAt = it }, Modifier.fillMaxWidth().testTag("schedule-time-picker"))
                }
                if (repeat == "Custom") {
                    OutlinedTextField(
                        customCron,
                        { customCron = it },
                        label = { Text("Cron expression") },
                        supportingText = { Text("Five fields: minute, hour, day of month, month, day of week") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth().testTag("schedule-cron"),
                    )
                }
                SelectorField(
                    label = "Timezone",
                    value = timezone,
                    options = scheduleTimezoneOptions(timezone).map { it to it },
                    onSelect = { timezone = it },
                    modifier = Modifier.fillMaxWidth().testTag("schedule-timezone"),
                )
                if (state.schedulePreview.isNotEmpty()) {
                    Text("Next five", color = DieterMuted, fontSize = 11.sp)
                    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                        state.schedulePreview.take(5).forEach { timestamp -> NeutralPill(schedulePreviewLabel(timestamp, timezone)) }
                    }
                }
            }
            FormSection(Icons.Outlined.ViewKanban, "Destination") {
                SelectorField(
                    label = "Board",
                    value = state.boards.firstOrNull { it.id == boardId }?.name ?: "Select a board",
                    options = state.boards.map { it.id to it.name },
                    onSelect = { next ->
                        boardId = next
                        labelIds.retainAll(state.boards.firstOrNull { it.id == next }?.labelsList.orEmpty().map { it.id }.toSet())
                    },
                    modifier = Modifier.fillMaxWidth().testTag("schedule-board"),
                )
                Text("Place each scheduled card in", color = DieterMuted, fontSize = 12.sp)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(
                        selected = action == "draft",
                        onClick = { action = "draft" },
                        label = { Text("Todo") },
                        modifier = Modifier.weight(1f).testTag("schedule-placement-todo"),
                    )
                    FilterChip(
                        selected = action == "run",
                        onClick = { action = "run" },
                        label = { Text("Running") },
                        modifier = Modifier.weight(1f).testTag("schedule-placement-running"),
                    )
                }
                Text(
                    if (action == "run") "The daemon creates the card and starts its agent turn when admission allows."
                    else "The daemon creates a draft in Todo and waits for you to start it.",
                    color = DieterMuted,
                    style = MaterialTheme.typography.bodySmall,
                )
                Text("Workspace", color = DieterMuted, fontSize = 12.sp)
                WorkspaceModeChips(workspaceMode) { workspaceMode = it }
                Text(workspaceMode.detail, color = DieterMuted, style = MaterialTheme.typography.bodySmall)
                val labels = state.boards.firstOrNull { it.id == boardId }?.labelsList.orEmpty()
                if (labels.isNotEmpty()) {
                    Text("Labels", color = DieterMuted, fontSize = 12.sp)
                    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        labels.forEach { label ->
                            FilterChip(
                                selected = label.id in labelIds,
                                onClick = { if (label.id in labelIds) labelIds.remove(label.id) else labelIds += label.id },
                                label = { Text(label.name) },
                            )
                        }
                    }
                }
            }
            FormSection(Icons.Outlined.CreditCard, "Card") {
                OutlinedTextField(
                    titleTemplate,
                    { titleTemplate = it },
                    label = { Text("Title template") },
                    placeholder = { Text("Daily update · {{date}}") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().testTag("schedule-title-template"),
                )
                ScheduleVariableButtons { variable -> titleTemplate = appendScheduleVariable(titleTemplate, variable) }
                OutlinedTextField(
                    prompt,
                    { prompt = it },
                    label = { Text("Agent task template") },
                    placeholder = { Text("Review {{project}} for {{date}} and summarize what needs attention.") },
                    minLines = 5,
                    modifier = Modifier.fillMaxWidth().testTag("schedule-prompt"),
                )
                ScheduleVariableButtons { variable -> prompt = appendScheduleVariable(prompt, variable) }
                Column(
                    Modifier.fillMaxWidth().background(DieterSurfaceHigh, RoundedCornerShape(12.dp)).padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text("EXAMPLE OUTPUT", color = DieterMuted, fontSize = 10.sp, letterSpacing = 1.2.sp)
                    Text(
                        renderScheduleTemplate(titleTemplate, scheduleTemplateVariables(state, name, boardId, timezone)),
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        renderScheduleTemplate(prompt, scheduleTemplateVariables(state, name, boardId, timezone)),
                        color = DieterMuted,
                        style = MaterialTheme.typography.bodySmall,
                        maxLines = 5,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            FormSection(Icons.Outlined.Bolt, "Agent") {
                ModelSelectors(
                    state, provider,
                    { next -> provider = next; selectedModel = state.harnesses.firstOrNull { it.id == next }?.defaultModel.orEmpty(); effort = "" },
                    harness, selectedModel, { selectedModel = it; effort = "" }, effort, { effort = it },
                    providerOptions, { id, value -> providerOptions = providerOptions + (id to value) },
                )
            }
            FormSection(Icons.Outlined.CalendarMonth, "Delivery & safety") {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Schedule enabled", Modifier.weight(1f))
                    Switch(enabled, { enabled = it })
                }
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(selected = openPolicy == "skip_if_open", onClick = { openPolicy = "skip_if_open" }, label = { Text("Skip if open") })
                    FilterChip(selected = openPolicy == "always", onClick = { openPolicy = "always" }, label = { Text("Always create") })
                    FilterChip(selected = busyPolicy == "queue", onClick = { busyPolicy = "queue" }, label = { Text("Queue if busy") })
                    FilterChip(selected = busyPolicy == "skip", onClick = { busyPolicy = "skip" }, label = { Text("Skip if busy") })
                }
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
internal fun CreationHeader(
    title: String,
    onClose: () -> Unit,
    eyebrow: String? = null,
    subtitle: String? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    Row(
        Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.background).padding(horizontal = 8.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
        Column(Modifier.weight(1f)) {
            if (!eyebrow.isNullOrBlank()) Text(eyebrow.uppercase(), color = DieterMuted, fontSize = 10.sp, letterSpacing = 1.4.sp)
            Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (!subtitle.isNullOrBlank()) Text(subtitle, color = DieterMuted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        trailing?.invoke()
    }
    HorizontalDivider(color = DieterOutline)
}

@Composable
private fun FormSection(
    icon: ImageVector,
    title: String,
    trailing: (@Composable () -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    Card(
        colors = CardDefaults.cardColors(containerColor = Color.Transparent),
        shape = RoundedCornerShape(18.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, DieterOutline),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(icon, null, tint = DieterShell, modifier = Modifier.size(18.dp))
                Spacer(Modifier.size(8.dp))
                Text(title, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                trailing?.invoke()
            }
            content()
        }
    }
}

@Composable
private fun ModelSelectors(
    state: DieterUiState,
    provider: String,
    onProviderChange: (String) -> Unit,
    harness: Harness?,
    model: String,
    onModelChange: (String) -> Unit,
    effort: String,
    onEffortChange: (String) -> Unit,
    providerOptions: Map<String, String>,
    onProviderOptionChange: (String, String) -> Unit,
) {
    val effortOptions = harness?.effortOptionsFor(model).orEmpty()
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        SelectorChip(
            value = harness?.name ?: "Agent",
            options = state.harnesses.map { it.id to it.name },
            onSelect = onProviderChange,
        )
        SelectorChip(
            value = harness?.modelsList?.firstOrNull { it.id == model }?.name ?: model.ifBlank { "Model" },
            options = harness?.modelsList.orEmpty().map { it.id to it.name },
            onSelect = onModelChange,
        )
        if (effortOptions.isNotEmpty()) {
            SelectorChip(
                value = effortOptions.firstOrNull { it.id == effort }?.name ?: effort.ifBlank { "Default effort" },
                options = listOf("" to "Default effort") + effortOptions.map { it.id to it.name },
                onSelect = onEffortChange,
            )
        }
        harness?.optionsList.orEmpty().forEach { option ->
            ProviderOptionControl(
                option = option,
                values = providerOptions,
                enabled = true,
                onValueChange = onProviderOptionChange,
            )
        }
    }
}

@Composable
private fun SelectorChip(value: String, options: List<Pair<String, String>>, onSelect: (String) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        AssistChip(onClick = { expanded = true }, label = { Text(value) })
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            options.forEach { (id, name) ->
                DropdownMenuItem(text = { Text(name) }, onClick = { expanded = false; onSelect(id) })
            }
        }
    }
}

@Composable
private fun SelectorField(
    label: String,
    value: String,
    options: List<Pair<String, String>>,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    var expanded by remember { mutableStateOf(false) }
    Box(modifier) {
        OutlinedTextField(
            value = value,
            onValueChange = {},
            readOnly = true,
            label = { Text(label) },
            trailingIcon = { Text("⌄", color = DieterMuted) },
            modifier = Modifier.fillMaxWidth(),
        )
        Box(
            Modifier
                .matchParentSize()
                .clickable(onClickLabel = "Select $label") { expanded = true },
        )
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            options.forEach { (id, name) ->
                DropdownMenuItem(text = { Text(name) }, onClick = { expanded = false; onSelect(id) })
            }
        }
    }
}

@Composable
internal fun NeutralPill(value: String) {
    Surface(shape = RoundedCornerShape(50), color = DieterSurfaceHigh, border = androidx.compose.foundation.BorderStroke(1.dp, DieterOutline)) {
        Text(value, color = DieterMuted, fontSize = 11.sp, modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp))
    }
}

@Composable
internal fun SurfaceErrorBanner(error: String?, onDismiss: () -> Unit) {
    if (error.isNullOrBlank()) return
    Row(
        Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.errorContainer).padding(start = 16.dp, end = 8.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(error, color = MaterialTheme.colorScheme.onErrorContainer, fontSize = 12.sp, modifier = Modifier.weight(1f))
        IconButton(onClick = onDismiss, modifier = Modifier.size(32.dp)) {
            Icon(Icons.Outlined.Close, "Dismiss error", modifier = Modifier.size(16.dp))
        }
    }
}

private fun titleFromPrompt(prompt: String): String {
    val firstLine = prompt.lineSequence().firstOrNull { it.isNotBlank() }?.trim().orEmpty().ifBlank { "New chat" }
    return if (firstLine.length <= 72) firstLine else firstLine.take(69) + "…"
}

internal fun scheduleRepeat(cron: String?): String = when (cron.orEmpty().trim()) {
    "0 9 * * 1-5" -> "Weekdays"
    "0 9 * * *" -> "Daily"
    "0 9 * * 1" -> "Weekly"
    "" -> "Weekdays"
    else -> {
        val parts = cron.orEmpty().trim().split(Regex("\\s+"))
        when (val day = parts.getOrNull(4)) {
            "1-5" -> "Weekdays"
            "*" -> "Daily"
            else -> if (day?.toIntOrNull()?.let { it in 0..6 } == true) "Weekly" else "Custom"
        }
    }
}

private fun scheduleTime(cron: String?): String {
    val parts = cron.orEmpty().trim().split(Regex("\\s+"))
    val minute = parts.getOrNull(0)?.toIntOrNull() ?: 0
    val hour = parts.getOrNull(1)?.toIntOrNull() ?: 9
    return "%02d:%02d".format(hour, minute)
}

private val scheduleWeekdays = listOf(
    "1" to "Monday", "2" to "Tuesday", "3" to "Wednesday", "4" to "Thursday",
    "5" to "Friday", "6" to "Saturday", "0" to "Sunday",
)

internal fun scheduleWeekday(cron: String?): String {
    val day = cron.orEmpty().trim().split(Regex("\\s+")).getOrNull(4)
    return day?.takeIf { candidate -> scheduleWeekdays.any { it.first == candidate } } ?: "1"
}

internal fun scheduleCron(repeat: String, runAt: String, weeklyDay: String, custom: String): String {
    if (repeat == "Custom") return custom
    val parts = runAt.split(':')
    val hour = parts.getOrNull(0)?.toIntOrNull()?.coerceIn(0, 23) ?: 9
    val minute = parts.getOrNull(1)?.toIntOrNull()?.coerceIn(0, 59) ?: 0
    val days = when (repeat) {
        "Weekdays" -> "1-5"
        "Weekly" -> weeklyDay.takeIf { candidate -> scheduleWeekdays.any { it.first == candidate } } ?: "1"
        else -> "*"
    }
    return "$minute $hour * * $days"
}

private fun scheduleTimingSummary(repeat: String, runAt: String, weeklyDay: String): String = when (repeat) {
    "Weekly" -> "${scheduleWeekdays.firstOrNull { it.first == weeklyDay }?.second ?: "Monday"} · $runAt"
    "Custom" -> "Custom cron"
    else -> "$repeat · $runAt"
}

internal fun schedulePreviewLabel(timestamp: String, timezone: String): String = runCatching {
    DateTimeFormatter.ofPattern("MMM d, HH:mm", Locale.getDefault())
        .format(Instant.parse(timestamp).atZone(ZoneId.of(timezone)))
}.getOrElse { timestamp.replace('T', ' ').substringBefore('+').substringBefore('Z').takeLast(11) }

private fun scheduleTimezoneOptions(selected: String): List<String> {
    val current = ZoneId.systemDefault().id
    return (listOf(selected, current, "UTC") + ZoneId.getAvailableZoneIds().sorted())
        .filter(String::isNotBlank)
        .distinct()
}

@Composable
private fun ScheduleTimeField(value: String, onValueChange: (String) -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val parts = value.split(':')
    val hour = parts.getOrNull(0)?.toIntOrNull()?.coerceIn(0, 23) ?: 9
    val minute = parts.getOrNull(1)?.toIntOrNull()?.coerceIn(0, 59) ?: 0
    Box(modifier) {
        OutlinedTextField(
            value = value,
            onValueChange = {},
            readOnly = true,
            label = { Text("Run at") },
            trailingIcon = { Icon(Icons.Outlined.Schedule, null) },
            modifier = Modifier.fillMaxWidth(),
        )
        Box(
            Modifier.matchParentSize().clickable(onClickLabel = "Choose run time") {
                TimePickerDialog(
                    context,
                    { _, selectedHour, selectedMinute -> onValueChange("%02d:%02d".format(selectedHour, selectedMinute)) },
                    hour,
                    minute,
                    true,
                ).show()
            },
        )
    }
}

private val scheduleTemplateVariables = listOf("date", "scheduled_at", "project", "board", "schedule")

@Composable
private fun ScheduleVariableButtons(onInsert: (String) -> Unit) {
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        scheduleTemplateVariables.forEach { variable ->
            AssistChip(onClick = { onInsert(variable) }, label = { Text("{{$variable}}", fontSize = 11.sp) })
        }
    }
}

internal fun appendScheduleVariable(value: String, variable: String): String {
    val token = "{{$variable}}"
    if (value.isEmpty()) return token
    return if (value.last().isWhitespace()) value + token else "$value $token"
}

internal fun renderScheduleTemplate(template: String, variables: Map<String, String>): String =
    variables.entries.fold(template) { rendered, (name, value) -> rendered.replace("{{$name}}", value) }

private fun scheduleTemplateVariables(
    state: DieterUiState,
    scheduleName: String,
    boardId: String,
    timezone: String,
): Map<String, String> {
    val instant = state.schedulePreview.firstOrNull()?.let { runCatching { Instant.parse(it) }.getOrNull() } ?: Instant.now()
    val zone = runCatching { ZoneId.of(timezone) }.getOrElse { ZoneId.systemDefault() }
    val date = DateTimeFormatter.ISO_LOCAL_DATE.format(instant.atZone(zone))
    return mapOf(
        "date" to date,
        "scheduled_at" to instant.toString(),
        "project" to (state.project?.name ?: "Project"),
        "board" to (state.boards.firstOrNull { it.id == boardId }?.name ?: "Board"),
        "schedule" to scheduleName.ifBlank { "Schedule" },
    )
}
