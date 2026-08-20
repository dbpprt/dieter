@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.nauclio.ui

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
import com.dbpprt.nauclio.ui.theme.NauclioAegean
import com.dbpprt.nauclio.ui.theme.NauclioMuted
import com.dbpprt.nauclio.ui.theme.NauclioOutline
import com.dbpprt.nauclio.ui.theme.NauclioSurface
import com.dbpprt.nauclio.ui.theme.NauclioSurfaceHigh
import com.dbpprt.nauclio.ui.theme.NauclioText
import com.dbpprt.nauclio.v1.Harness
import com.dbpprt.nauclio.v1.MessagePart
import com.dbpprt.nauclio.v1.Schedule
import com.dbpprt.nauclio.v1.ScheduleDraft
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

@Composable
fun NewConversationScreen(
    state: NauclioUiState,
    model: NauclioViewModel,
    chat: Boolean,
    contentPadding: PaddingValues,
) {
    var title by remember { mutableStateOf("") }
    var prompt by remember { mutableStateOf("") }
    var provider by remember(state.harnesses) { mutableStateOf(state.harnesses.firstOrNull()?.id.orEmpty()) }
    val harness = state.harnesses.firstOrNull { it.id == provider } ?: state.harnesses.firstOrNull()
    var selectedModel by remember(provider, harness) { mutableStateOf(harness?.defaultModel.orEmpty()) }
    var effort by remember(provider, selectedModel) { mutableStateOf("") }
    var lane by remember(state.selectedLane) {
        mutableStateOf(state.selectedLane.ifBlank { state.board?.lanesList?.firstOrNull()?.id.orEmpty() })
    }
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
                            model.createConversation(
                                title = title.trim(),
                                prompt = prompt.trim(),
                                chat = false,
                                provider = provider,
                                model = selectedModel,
                                effort = effort,
                                lane = lane,
                                labelIds = labelIds.toList(),
                                deferStart = shouldDeferConversationStart(chat = false, lane = lane),
                                attachments = attachments.toList(),
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
                canSubmit = canSubmit && !state.working,
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
                        lane = "",
                        labelIds = emptyList(),
                        deferStart = shouldDeferConversationStart(chat = true, lane = ""),
                        attachments = attachments.toList(),
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
                lane = lane,
                onLaneChange = { lane = it },
                labelIds = labelIds,
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
    state: NauclioUiState,
    onProjectChange: (String) -> Unit,
    provider: String,
    onProviderChange: (String) -> Unit,
    harness: Harness?,
    model: String,
    onModelChange: (String) -> Unit,
    effort: String,
    onEffortChange: (String) -> Unit,
    canSubmit: Boolean,
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
            Surface(shape = RoundedCornerShape(18.dp), color = NauclioSurfaceHigh, modifier = Modifier.size(64.dp)) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(Icons.Outlined.ChatBubbleOutline, null, tint = NauclioAegean, modifier = Modifier.size(28.dp))
                }
            }
            Spacer(Modifier.height(18.dp))
            Text("Chat with your local agent", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(10.dp))
            Text(
                "Runs on your machine with full access to this project's files. Ask questions, make changes, or explore the code.",
                color = NauclioMuted,
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
                        modifier = Modifier.fillMaxWidth().border(1.dp, NauclioOutline, RoundedCornerShape(14.dp)),
                        shape = RoundedCornerShape(14.dp),
                        colors = ButtonDefaults.textButtonColors(contentColor = NauclioText),
                    ) {
                        Icon(icon, null, tint = NauclioAegean, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.size(10.dp))
                        Text(text, modifier = Modifier.weight(1f))
                    }
                }
            }
        }
        SelectorField(
            label = "Project",
            value = state.project?.let { project ->
                state.projectHosts[project.id]?.hostname
                    ?.takeIf(String::isNotBlank)
                    ?.let { host -> "${project.name} · $host" }
                    ?: project.name
            } ?: "Select a project",
            options = chatProjectOptions(state.projects, state.projectHosts),
            onSelect = onProjectChange,
            modifier = Modifier.fillMaxWidth().testTag("chat-project-selector"),
        )
        Spacer(Modifier.height(8.dp))
        ModelSelectors(state, provider, onProviderChange, harness, model, onModelChange, effort, onEffortChange)
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
                    focusedContainerColor = NauclioSurface,
                    unfocusedContainerColor = NauclioSurface,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                ),
                modifier = Modifier.weight(1f).testTag("conversation-prompt"),
            )
            FloatingActionButton(
                onClick = { if (canSubmit) onSubmit() },
                modifier = Modifier.size(52.dp).testTag("create-chat"),
                containerColor = NauclioAegean,
                contentColor = Color(0xFF071426),
            ) { Icon(Icons.AutoMirrored.Filled.Send, "Start chat") }
        }
    }
}

@Composable
private fun NewCardBody(
    state: NauclioUiState,
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
    lane: String,
    onLaneChange: (String) -> Unit,
    labelIds: MutableList<String>,
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
            Text("Up to 4 attachments · 5 MB each · 6 MB total", color = NauclioMuted, fontSize = 11.sp)
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
        FormSection(Icons.Outlined.Bolt, "Agent") {
            ModelSelectors(state, provider, onProviderChange, harness, model, onModelChange, effort, onEffortChange)
        }
        Text(
            if (lane == "running") "The first message starts immediately." else "The card is saved as a draft in Todo.",
            color = NauclioMuted,
            style = MaterialTheme.typography.bodySmall,
        )
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
fun NewBoardScreen(state: NauclioUiState, model: NauclioViewModel, contentPadding: PaddingValues) {
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
                    color = NauclioMuted,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            Text("Completed conversations are kept until you change this board's retention setting.", color = NauclioMuted, fontSize = 12.sp)
        }
    }
}

private fun compactBoardPath(path: String): String {
    val marker = "/Development/"
    return if (marker in path) "~$marker${path.substringAfter(marker)}" else path
}

@Composable
fun ScheduleEditorScreen(
    state: NauclioUiState,
    model: NauclioViewModel,
    schedule: Schedule?,
    contentPadding: PaddingValues,
) {
    var name by remember(schedule?.id) { mutableStateOf(schedule?.name.orEmpty()) }
    var description by remember(schedule?.id) { mutableStateOf(schedule?.description.orEmpty()) }
    var customCron by remember(schedule?.id) { mutableStateOf(schedule?.cron ?: "0 9 * * 1-5") }
    var repeat by remember(schedule?.id) { mutableStateOf(scheduleRepeat(schedule?.cron)) }
    var runAt by remember(schedule?.id) { mutableStateOf(scheduleTime(schedule?.cron)) }
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
    val labelIds = remember(schedule?.id) { mutableStateListOf<String>().also { it += schedule?.labelIdsList.orEmpty() } }
    var openPolicy by remember(schedule?.id) { mutableStateOf(schedule?.openCardPolicy ?: "skip_if_open") }
    var busyPolicy by remember(schedule?.id) { mutableStateOf(schedule?.busyPolicy ?: "queue") }
    val cron = scheduleCron(repeat, runAt, customCron)
    val canSave = name.isNotBlank() && cron.isNotBlank() && prompt.isNotBlank() && provider.isNotBlank() && boardId.isNotBlank()

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
                .setOpenCardPolicy(openPolicy)
                .setMisfirePolicy("latest")
                .setBusyPolicy(busyPolicy)
                .addAllLabelIds(labelIds)
                .build(),
        )
    }

    Column(Modifier.fillMaxSize().padding(contentPadding)) {
        CreationHeader(
            eyebrow = state.board?.name ?: "Board",
            title = if (schedule == null) "New schedule" else "Edit schedule",
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
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(name, { name = it }, label = { Text("Schedule name") }, singleLine = true, modifier = Modifier.weight(1f).testTag("schedule-name"))
                SelectorField(
                    label = "Destination board",
                    value = state.boards.firstOrNull { it.id == boardId }?.name ?: "Board",
                    options = state.boards.map { it.id to it.name },
                    onSelect = { next -> boardId = next; labelIds.retainAll(state.boards.firstOrNull { it.id == next }?.labelsList.orEmpty().map { it.id }.toSet()) },
                    modifier = Modifier.weight(1f),
                )
            }
            OutlinedTextField(description, { description = it }, label = { Text("Description") }, placeholder = { Text("Prepare the morning maintenance card") }, modifier = Modifier.fillMaxWidth())
            FormSection(Icons.Outlined.Schedule, "Timing", trailing = { Text("$timezone · local", color = NauclioMuted, fontSize = 11.sp) }) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    SelectorField(
                        label = "Repeats",
                        value = repeat,
                        options = listOf("Weekdays", "Daily", "Weekly", "Custom").map { it to it },
                        onSelect = { repeat = it },
                        modifier = Modifier.weight(1f),
                    )
                    OutlinedTextField(
                        runAt,
                        { runAt = it.filter { character -> character.isDigit() || character == ':' }.take(5) },
                        label = { Text("Run at") },
                        singleLine = true,
                        modifier = Modifier.weight(1f),
                    )
                }
                if (repeat == "Custom") {
                    OutlinedTextField(customCron, { customCron = it }, label = { Text("Cron schedule") }, singleLine = true, modifier = Modifier.fillMaxWidth().testTag("schedule-cron"))
                }
                OutlinedTextField(timezone, { timezone = it }, label = { Text("Timezone") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                if (state.schedulePreview.isNotEmpty()) {
                    Text("Next five", color = NauclioMuted, fontSize = 11.sp)
                    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                        state.schedulePreview.take(5).forEach { timestamp -> NeutralPill(schedulePreviewLabel(timestamp)) }
                    }
                }
            }
            FormSection(Icons.Outlined.CreditCard, "Card") {
                OutlinedTextField(titleTemplate, { titleTemplate = it }, label = { Text("Title template") }, modifier = Modifier.fillMaxWidth())
                Text("Variables: date, scheduled_at, project, board, schedule.", color = NauclioMuted, fontSize = 11.sp)
                OutlinedTextField(prompt, { prompt = it }, label = { Text("Agent task") }, minLines = 3, modifier = Modifier.fillMaxWidth().testTag("schedule-prompt"))
                val labels = state.boards.firstOrNull { it.id == boardId }?.labelsList.orEmpty()
                if (labels.isNotEmpty()) {
                    Text("Labels", color = NauclioMuted, fontSize = 12.sp)
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
            FormSection(Icons.Outlined.Bolt, "Action") {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(selected = action == "draft", onClick = { action = "draft" }, label = { Text("Create draft") })
                    FilterChip(selected = action == "run", onClick = { action = "run" }, label = { Text("Create & run") })
                }
                ModelSelectors(
                    state, provider,
                    { next -> provider = next; selectedModel = state.harnesses.firstOrNull { it.id == next }?.defaultModel.orEmpty(); effort = "" },
                    harness, selectedModel, { selectedModel = it; effort = "" }, effort, { effort = it },
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
            if (!eyebrow.isNullOrBlank()) Text(eyebrow.uppercase(), color = NauclioMuted, fontSize = 10.sp, letterSpacing = 1.4.sp)
            Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (!subtitle.isNullOrBlank()) Text(subtitle, color = NauclioMuted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        trailing?.invoke()
    }
    HorizontalDivider(color = NauclioOutline)
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
        border = androidx.compose.foundation.BorderStroke(1.dp, NauclioOutline),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(icon, null, tint = NauclioAegean, modifier = Modifier.size(18.dp))
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
    state: NauclioUiState,
    provider: String,
    onProviderChange: (String) -> Unit,
    harness: Harness?,
    model: String,
    onModelChange: (String) -> Unit,
    effort: String,
    onEffortChange: (String) -> Unit,
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
            trailingIcon = { Text("⌄", color = NauclioMuted) },
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
    Surface(shape = RoundedCornerShape(50), color = NauclioSurfaceHigh, border = androidx.compose.foundation.BorderStroke(1.dp, NauclioOutline)) {
        Text(value, color = NauclioMuted, fontSize = 11.sp, modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp))
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

private fun scheduleRepeat(cron: String?): String = when (cron.orEmpty().trim()) {
    "0 9 * * 1-5" -> "Weekdays"
    "0 9 * * *" -> "Daily"
    "0 9 * * 1" -> "Weekly"
    "" -> "Weekdays"
    else -> {
        val parts = cron.orEmpty().trim().split(Regex("\\s+"))
        when (parts.getOrNull(4)) {
            "1-5" -> "Weekdays"
            "*" -> "Daily"
            "1" -> "Weekly"
            else -> "Custom"
        }
    }
}

private fun scheduleTime(cron: String?): String {
    val parts = cron.orEmpty().trim().split(Regex("\\s+"))
    val minute = parts.getOrNull(0)?.toIntOrNull() ?: 0
    val hour = parts.getOrNull(1)?.toIntOrNull() ?: 9
    return "%02d:%02d".format(hour, minute)
}

private fun scheduleCron(repeat: String, runAt: String, custom: String): String {
    if (repeat == "Custom") return custom
    val parts = runAt.split(':')
    val hour = parts.getOrNull(0)?.toIntOrNull()?.coerceIn(0, 23) ?: 9
    val minute = parts.getOrNull(1)?.toIntOrNull()?.coerceIn(0, 59) ?: 0
    val days = when (repeat) {
        "Weekdays" -> "1-5"
        "Weekly" -> "1"
        else -> "*"
    }
    return "$minute $hour * * $days"
}

private fun schedulePreviewLabel(timestamp: String): String = runCatching {
    DateTimeFormatter.ofPattern("MMM d, HH:mm", Locale.getDefault())
        .format(Instant.parse(timestamp).atZone(ZoneId.systemDefault()))
}.getOrElse { timestamp.replace('T', ' ').substringBefore('+').substringBefore('Z').takeLast(11) }
