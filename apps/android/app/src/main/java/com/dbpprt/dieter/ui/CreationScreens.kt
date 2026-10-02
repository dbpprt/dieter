@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.compose.runtime.collectAsState
import com.dbpprt.dieter.core.admin.Administration
import com.dbpprt.dieter.core.composition.Attachments
import com.dbpprt.dieter.core.composition.Creation
import com.dbpprt.dieter.api.v1.HarnessSelection
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
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.core.composition.TaskDraftEditor
import com.dbpprt.dieter.core.composition.TaskDrafts
import com.dbpprt.dieter.core.composition.WorkspaceMode
import com.dbpprt.dieter.core.composition.frozen
import com.dbpprt.dieter.core.composition.task
import com.dbpprt.dieter.core.presentation.DisplayPaths
import com.dbpprt.dieter.core.schedules.Cadence
import com.dbpprt.dieter.core.schedules.CadenceKind
import com.dbpprt.dieter.core.schedules.ScheduleDrafts
import com.dbpprt.dieter.core.schedules.ScheduleTemplates
import com.dbpprt.dieter.core.search.ListFilters
import com.dbpprt.dieter.core.selection.AgentControls
import com.dbpprt.dieter.core.selection.Selections
import com.dbpprt.dieter.core.state.CaptureDraft
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterOutline
import com.dbpprt.dieter.ui.theme.DieterSurface
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh
import com.dbpprt.dieter.ui.theme.DieterText
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.Schedule
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import com.dbpprt.dieter.ui.theme.DieterAbyss

@Composable
fun NewConversationScreen(
    state: DieterUiState,
    model: DieterViewModel,
    chat: Boolean,
    contentPadding: PaddingValues,
) {
    val chosenCheckout = state.creationCheckout
    val machineOnline = state.creationMachine?.online == true
    LaunchedEffect(chosenCheckout?.id, machineOnline, state.catalogState) {
        if (Creation.needsCatalog(chosenCheckout, machineOnline, state.catalogState)) model.prepareCreationCheckout(chosenCheckout!!.id)
    }
    val catalog = state.creationCatalog(chat).orEmpty()
    // A chat starts at once and is not journaled; a task edits the board's durable draft.
    val chatEditor = remember(chat, state.selectedProjectId) { if (chat) TaskDraftEditor(CaptureDraft(id = "chat")) else null }
    val editor = chatEditor ?: model.activeCapture
    if (editor == null) {
        LoadingState(Modifier.padding(contentPadding))
        return
    }
    val draft by editor.state.collectAsState(context = Dispatchers.Main.immediate)
    val saveError by editor.error.collectAsState()
    LaunchedEffect(editor.id, catalog) {
        if (chat) model.initializeChat(editor) else model.initializeTask(editor, quick = false)
    }
    val controls = AgentControls(TaskDrafts.selection(draft), catalog)
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
            var refused: String? = null
            if (incoming.isNotEmpty()) editor.edit { current -> TaskDrafts.attach(current, incoming).getOrElse { error -> refused = error.message; current } }
            attachmentError = refused ?: results.firstNotNullOfOrNull { it.exceptionOrNull()?.message }
        }
    }
    val imagePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia(Attachments.MAX_COUNT),
    ) { uris -> addPickedAttachments(uris, imagesOnly = true) }
    val filePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments(),
    ) { uris -> addPickedAttachments(uris, imagesOnly = false) }
    val canSubmit = !state.working && model.creationProblem(draft, chat) == null

    Column(Modifier.fillMaxSize().padding(contentPadding)) {
        CreationHeader(
            eyebrow = if (chat) null else state.board?.name ?: "Board",
            title = if (chat) "New chat" else "New task",
            subtitle = if (chat) "${state.project?.name ?: "Project"} · Standalone chat" else state.project?.name,
            onClose = model::closeSurface,
            trailing = if (chat) {
                { NeutralPill("New") }
            } else {
                {
                    Button(onClick = { model.submitTask(editor) }, enabled = canSubmit) {
                        Text(Creation.submitTitle(draft.task.lane))
                    }
                }
            },
        )
        SurfaceErrorBanner(state.error, model::clearError)
        CreationDestinationPicker(state, model::selectCreationCheckout, Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
        if (!chat && TaskDrafts.unavailableLabels(draft, state.board).isNotEmpty()) {
            TextButton(onClick = { editor.edit { TaskDrafts.removeUnavailableLabels(it, state.board) } }) {
                Text("Remove labels unavailable on this board")
            }
        }
        if (!chat && !machineOnline) Text(
            Creation.offlineHint(state.catalogState),
            modifier = Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.bodySmall,
        )
        (attachmentError ?: saveError)?.let { message ->
            Text(
                message,
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
            )
        }
        if (chat) {
            NewChatBody(
                prompt = draft.task.prompt,
                onPromptChange = { value -> editor.edit { TaskDrafts.prompt(it, value) } },
                state = state,
                onProjectChange = model::selectProject,
                controls = controls,
                onSelectionChange = { selection -> editor.edit { TaskDrafts.choose(it, selection) } },
                canSubmit = canSubmit,
                workspaceMode = TaskDrafts.workspaceMode(draft),
                onWorkspaceModeChange = { mode -> editor.edit { TaskDrafts.workspaceMode(it, mode) } },
                attachments = draft.task.attachments,
                onAttach = { attachmentPickerVisible = true },
                onRemoveAttachment = { index -> editor.edit { TaskDrafts.removeAttachment(it, index) } },
                onSubmit = { model.createChat(editor.state.value) },
            )
        } else if (draft.frozen) {
            Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(TaskDrafts.creationTitle(draft), style = MaterialTheme.typography.titleMedium)
                Text(draft.task.prompt)
                TaskAttachmentControls(editor, model.taskCaptures)
            }
        } else {
            TextButton(onClick = model::returnToQuickTask) { Text("Quick task") }
            NewCardBody(
                state = state,
                draft = draft,
                onTitleChange = { value -> editor.edit { TaskDrafts.title(it, value) } },
                onPromptChange = { value -> editor.edit { TaskDrafts.prompt(it, value) } },
                controls = controls,
                onSelectionChange = { selection -> editor.edit { TaskDrafts.choose(it, selection) } },
                onLaneChange = { lane -> editor.edit { TaskDrafts.lane(it, lane) } },
                onToggleLabel = { id -> editor.edit { TaskDrafts.toggleLabel(it, id) } },
                onWorkspaceModeChange = { mode -> editor.edit { TaskDrafts.workspaceMode(it, mode) } },
                attachmentContent = { TaskAttachmentControls(editor, model.taskCaptures) { model.discardTaskDraft(editor) } },
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
    controls: AgentControls,
    onSelectionChange: (HarnessSelection) -> Unit,
    canSubmit: Boolean,
    workspaceMode: WorkspaceMode,
    onWorkspaceModeChange: (WorkspaceMode) -> Unit,
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
            value = state.project?.name ?: "Select a project",
            options = ListFilters.projectOptions(state.projects),
            onSelect = onProjectChange,
            modifier = Modifier.fillMaxWidth().testTag("chat-project-selector"),
        )
        Spacer(Modifier.height(8.dp))
        ModelSelectors(controls, onSelectionChange)
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
internal fun NewCardBody(
    state: DieterUiState,
    draft: CaptureDraft,
    onTitleChange: (String) -> Unit,
    onPromptChange: (String) -> Unit,
    controls: AgentControls,
    onSelectionChange: (HarnessSelection) -> Unit,
    onLaneChange: (String) -> Unit,
    onToggleLabel: (String) -> Unit,
    onWorkspaceModeChange: (WorkspaceMode) -> Unit,
    attachmentContent: @Composable () -> Unit,
) {
    val task = draft.task
    val workspaceMode = TaskDrafts.workspaceMode(draft)
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        OutlinedTextField(task.title, onTitleChange, label = { Text("Title (optional)") }, singleLine = true, modifier = Modifier.fillMaxWidth().testTag("conversation-title"))
        OutlinedTextField(task.prompt, onPromptChange, label = { Text("Agent task") }, minLines = 6, modifier = Modifier.fillMaxWidth().testTag("conversation-prompt"))
        FormSection(Icons.Outlined.AttachFile, "Attachments", modifier = Modifier.testTag("card-section-attachments")) { attachmentContent() }
        FormSection(Icons.Outlined.ViewKanban, "Start in", modifier = Modifier.testTag("card-section-lane")) {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Creation.startLanes(state.board).forEach { boardLane ->
                    FilterChip(
                        selected = task.lane == boardLane.id,
                        onClick = { onLaneChange(boardLane.id) },
                        label = { Text(boardLane.name) },
                        modifier = Modifier.testTag("create-lane-${boardLane.id}"),
                    )
                }
            }
        }
        if (state.board?.labels.orEmpty().isNotEmpty()) {
            FormSection(Icons.Outlined.CreditCard, "Labels", modifier = Modifier.testTag("card-section-labels")) {
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    state.board?.labels.orEmpty().forEach { label ->
                        FilterChip(
                            selected = label.id in task.label_ids,
                            onClick = { onToggleLabel(label.id) },
                            label = { Text(label.name) },
                        )
                    }
                }
            }
        }
        FormSection(Icons.Outlined.AccountTree, "Workspace", modifier = Modifier.testTag("card-section-workspace")) {
            WorkspaceModeChips(workspaceMode, onWorkspaceModeChange)
            Text(workspaceMode.detail, color = DieterMuted, style = MaterialTheme.typography.bodySmall)
        }
        FormSection(Icons.Outlined.Bolt, "Agent", modifier = Modifier.testTag("card-section-agent")) {
            ModelSelectors(controls, onSelectionChange)
        }
        Text(
            Creation.startNote(task.lane),
            color = DieterMuted,
            style = MaterialTheme.typography.bodySmall,
        )
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun WorkspaceModeChips(
    selected: WorkspaceMode,
    onSelect: (WorkspaceMode) -> Unit,
) {
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        WorkspaceMode.choices.forEach { mode ->
            FilterChip(
                selected = selected == mode,
                onClick = { onSelect(mode) },
                label = { Text(mode.choiceTitle) },
                modifier = Modifier.testTag("workspace-mode-${mode.wire}"),
            )
        }
    }
}

@Composable
fun NewBoardScreen(state: DieterUiState, model: DieterViewModel, contentPadding: PaddingValues) {
    var name by remember { mutableStateOf("") }
    var description by remember { mutableStateOf("") }
    var workflow by remember { mutableStateOf(Administration.DEFAULT_WORKFLOW) }
    var baseRemote by remember(state.project?.id) { mutableStateOf(state.project?.base_remote.orEmpty()) }
    var remotePublishMode by remember { mutableStateOf(Administration.DEFAULT_PUBLISH_MODE) }
    val canCreate = name.isNotBlank() && state.selectedProjectId.isNotBlank() && !state.working

    Column(Modifier.fillMaxSize().padding(contentPadding)) {
        CreationHeader(
            eyebrow = state.project?.name ?: "Project",
            title = "New board",
            subtitle = DisplayPaths.compact(state.project?.path.orEmpty()),
            onClose = model::closeSurface,
            trailing = {
                Button(
                    onClick = { model.createBoard(name.trim(), workflow, description.trim(), openAfterCreate = true, baseRemote = baseRemote, remotePublishMode = remotePublishMode) },
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
                Administration.WORKFLOWS.forEach { value ->
                    FilterChip(
                        selected = workflow == value,
                        onClick = { workflow = value },
                        label = { Text(Administration.workflowLanes(value)) },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                Text(Administration.workflowDetail(workflow), color = DieterMuted, style = MaterialTheme.typography.bodySmall)
            }
            FormSection(Icons.Outlined.AccountTree, "Git publishing") {
                OutlinedTextField(
                    value = baseRemote,
                    onValueChange = { baseRemote = it },
                    label = { Text("Default remote") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Administration.PUBLISH_MODES.forEach { value ->
                        FilterChip(selected = remotePublishMode == value, onClick = { remotePublishMode = value }, label = { Text(Administration.publishModeTitle(value)) })
                    }
                }
            }
            Text("Completed conversations are kept until you change this board's retention setting.", color = DieterMuted, fontSize = 12.sp)
        }
    }
}

@Composable
fun ScheduleEditorScreen(
    state: DieterUiState,
    model: DieterViewModel,
    schedule: Schedule?,
    contentPadding: PaddingValues,
) {
    var draft by remember(schedule?.id) {
        mutableStateOf(ScheduleDrafts.make(schedule, state.selectedProjectId, ZoneId.systemDefault().id, state.boards, state.selectedBoardId, state.harnesses))
    }
    var cadence by remember(schedule?.id) { mutableStateOf(Cadence.parse(draft.cron)) }
    val cron = cadence.cron()
    val controls = AgentControls(ScheduleDrafts.selection(draft), state.harnesses)
    val board = state.boards.firstOrNull { it.id == draft.board_id }
    val canSave = ScheduleDrafts.canSave(draft.copy(cron = cron))
    val view = state.scheduleWorkspace

    LaunchedEffect(cron, draft.timezone) { model.previewSchedule(cron, draft.timezone) }

    Column(Modifier.fillMaxSize().padding(contentPadding)) {
        CreationHeader(
            eyebrow = state.project?.name,
            title = if (schedule == null) ScheduleDrafts.NEW_TITLE else ScheduleDrafts.EDIT_TITLE,
            subtitle = cadence.summary(draft.timezone),
            onClose = model::closeSurface,
            trailing = {
                Button(onClick = { model.saveSchedule(schedule?.id.orEmpty(), draft.copy(cron = cron)) }, enabled = canSave && !state.working) {
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
                draft.name,
                { draft = draft.copy(name = it) },
                label = { Text("Schedule name") },
                placeholder = { Text("Morning project check") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().testTag("schedule-name"),
            )
            OutlinedTextField(
                draft.description,
                { draft = draft.copy(description = it) },
                label = { Text("Description") },
                placeholder = { Text("What this automation is responsible for") },
                minLines = 2,
                modifier = Modifier.fillMaxWidth(),
            )
            FormSection(Icons.Outlined.Schedule, "Timing") {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    SelectorField(
                        label = "Repeats",
                        value = cadence.kind.title,
                        options = CadenceKind.entries.map { it.name to it.title },
                        onSelect = { kind -> cadence = cadence.withKind(CadenceKind.valueOf(kind)) },
                        modifier = Modifier.weight(1f),
                    )
                    if (cadence.kind == CadenceKind.WEEKLY) {
                        SelectorField(
                            label = "Day",
                            value = Cadence.weekdayName(cadence.weekday),
                            options = Cadence.WEEKDAYS.map { (day, name) -> day.toString() to name },
                            onSelect = { day -> cadence = cadence.copy(weekday = day.toInt()) },
                            modifier = Modifier.weight(1f).testTag("schedule-weekday"),
                        )
                    }
                }
                if (cadence.kind != CadenceKind.CUSTOM) {
                    ScheduleTimeField(cadence, { hour, minute -> cadence = cadence.copy(hour = hour, minute = minute) }, Modifier.fillMaxWidth().testTag("schedule-time-picker"))
                } else {
                    OutlinedTextField(
                        cadence.custom,
                        { cadence = cadence.copy(custom = it) },
                        label = { Text("Cron expression") },
                        supportingText = { Text(ScheduleDrafts.CRON_HELP) },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth().testTag("schedule-cron"),
                    )
                }
                SelectorField(
                    label = "Timezone",
                    value = draft.timezone,
                    options = ScheduleDrafts.timezoneOptions(draft.timezone, ZoneId.systemDefault().id, ZoneId.getAvailableZoneIds().toList()).map { it to it },
                    onSelect = { draft = draft.copy(timezone = it) },
                    modifier = Modifier.fillMaxWidth().testTag("schedule-timezone"),
                )
                val previewError = view.previewError
                when {
                    view.previewLoading -> CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    previewError != null -> Text(previewError, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                    view.preview.isNotEmpty() -> {
                        Text("Next five", color = DieterMuted, fontSize = 11.sp)
                        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                            view.preview.take(5).forEach { timestamp -> NeutralPill(scheduleTimeLabel(timestamp, draft.timezone)) }
                        }
                    }
                }
            }
            FormSection(Icons.Outlined.ViewKanban, "Destination") {
                SelectorField(
                    label = "Board",
                    value = board?.name ?: "Select a board",
                    options = state.boards.map { it.id to it.name },
                    onSelect = { next -> state.boards.firstOrNull { it.id == next }?.let { draft = ScheduleDrafts.onBoard(draft, it) } },
                    modifier = Modifier.fillMaxWidth().testTag("schedule-board"),
                )
                Text("Place each scheduled card in", color = DieterMuted, fontSize = 12.sp)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf(ScheduleDrafts.DRAFT, ScheduleDrafts.RUN).forEach { action ->
                        FilterChip(
                            selected = draft.action == action,
                            onClick = { draft = draft.copy(action = action) },
                            label = { Text(ScheduleDrafts.placementTitle(action)) },
                            modifier = Modifier.weight(1f).testTag(if (action == ScheduleDrafts.RUN) "schedule-placement-running" else "schedule-placement-todo"),
                        )
                    }
                }
                Text(ScheduleDrafts.placementDetail(draft.action), color = DieterMuted, style = MaterialTheme.typography.bodySmall)
                Text("Workspace", color = DieterMuted, fontSize = 12.sp)
                val workspaceMode = WorkspaceMode.parse(draft.workspace_mode)
                WorkspaceModeChips(workspaceMode) { draft = draft.copy(workspace_mode = it.wire) }
                Text(workspaceMode.detail, color = DieterMuted, style = MaterialTheme.typography.bodySmall)
                val labels = board?.labels.orEmpty()
                if (labels.isNotEmpty()) {
                    Text("Labels", color = DieterMuted, fontSize = 12.sp)
                    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        labels.forEach { label ->
                            FilterChip(
                                selected = label.id in draft.label_ids,
                                onClick = { draft = ScheduleDrafts.toggleLabel(draft, label.id) },
                                label = { Text(label.name) },
                            )
                        }
                    }
                }
            }
            FormSection(Icons.Outlined.CreditCard, "Card") {
                OutlinedTextField(
                    draft.title_template,
                    { draft = draft.copy(title_template = it) },
                    label = { Text("Title template") },
                    placeholder = { Text("Daily update · {{date}}") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().testTag("schedule-title-template"),
                )
                ScheduleVariableButtons { variable -> draft = draft.copy(title_template = ScheduleTemplates.insert(draft.title_template, variable)) }
                OutlinedTextField(
                    draft.prompt_template,
                    { draft = draft.copy(prompt_template = it) },
                    label = { Text("Agent task template") },
                    placeholder = { Text("Review {{project}} for {{date}} and summarize what needs attention.") },
                    minLines = 5,
                    modifier = Modifier.fillMaxWidth().testTag("schedule-prompt"),
                )
                ScheduleVariableButtons { variable -> draft = draft.copy(prompt_template = ScheduleTemplates.insert(draft.prompt_template, variable)) }
                val example = scheduleExampleValues(view.preview, state.project?.name, draft.name, board?.name, draft.timezone)
                Column(
                    Modifier.fillMaxWidth().background(DieterSurfaceHigh, RoundedCornerShape(12.dp)).padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text("EXAMPLE OUTPUT", color = DieterMuted, fontSize = 10.sp, letterSpacing = 1.2.sp)
                    Text(ScheduleTemplates.example(draft.title_template, example, ScheduleTemplates.TITLE_PLACEHOLDER), fontWeight = FontWeight.SemiBold)
                    Text(
                        ScheduleTemplates.example(draft.prompt_template, example, ScheduleTemplates.PROMPT_PLACEHOLDER),
                        color = DieterMuted,
                        style = MaterialTheme.typography.bodySmall,
                        maxLines = 5,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            FormSection(Icons.Outlined.Bolt, "Agent") {
                ModelSelectors(controls) { selection -> draft = ScheduleDrafts.choose(draft, selection) }
            }
            FormSection(Icons.Outlined.CalendarMonth, "Delivery & safety") {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Schedule enabled", Modifier.weight(1f))
                    Switch(draft.enabled, { draft = draft.copy(enabled = it) })
                }
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    ScheduleDrafts.OPEN_POLICIES.forEach { (policy, title) ->
                        FilterChip(selected = draft.open_card_policy == policy, onClick = { draft = draft.copy(open_card_policy = policy) }, label = { Text(title) })
                    }
                }
                Text(ScheduleDrafts.MISFIRE_NOTE, color = DieterMuted, style = MaterialTheme.typography.bodySmall)
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
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    Card(
        colors = CardDefaults.cardColors(containerColor = Color.Transparent),
        shape = RoundedCornerShape(18.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, DieterOutline),
        modifier = modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(icon, null, tint = DieterShell, modifier = Modifier.size(18.dp))
                Spacer(Modifier.size(8.dp))
                Text(title, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            }
            content()
        }
    }
}

@Composable
private fun ModelSelectors(controls: AgentControls, onSelectionChange: (HarnessSelection) -> Unit) {
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        SelectorChip(
            value = controls.providerLabel,
            options = controls.harnesses.map { it.id to it.name },
            onSelect = { id -> controls.harnesses.firstOrNull { it.id == id }?.let { onSelectionChange(controls.choosingProvider(it)) } },
            modifier = Modifier.testTag("creation-provider"),
        )
        SelectorChip(
            value = controls.modelLabel,
            options = controls.harness?.models.orEmpty().map { it.id to it.name },
            onSelect = { onSelectionChange(controls.choosingModel(it)) },
            modifier = Modifier.testTag("creation-model"),
        )
        if (controls.efforts.isNotEmpty()) {
            SelectorChip(
                value = controls.effortLabel,
                options = listOf(Selections.DEFAULT_EFFORT to "Default effort") + controls.efforts.map { it.id to it.name },
                onSelect = { onSelectionChange(controls.choosingEffort(it)) },
                modifier = Modifier.testTag("creation-effort"),
            )
        }
        controls.options.forEach { option ->
            ProviderOptionControl(
                option = option,
                value = controls.optionValue(option),
                enabled = controls.optionEnabled(option),
                onValueChange = { id, value -> onSelectionChange(controls.settingOption(id, value)) },
            )
        }
    }
}

@Composable
private fun SelectorChip(
    value: String,
    options: List<Pair<String, String>>,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        AssistChip(onClick = { expanded = true }, label = { Text(value) }, modifier = modifier)
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

@Composable
private fun ScheduleTimeField(cadence: Cadence, onChange: (hour: Int, minute: Int) -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    Box(modifier) {
        OutlinedTextField(
            value = cadence.time,
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
                    { _, selectedHour, selectedMinute -> onChange(selectedHour, selectedMinute) },
                    cadence.hour,
                    cadence.minute,
                    true,
                ).show()
            },
        )
    }
}

@Composable
private fun ScheduleVariableButtons(onInsert: (String) -> Unit) {
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        ScheduleTemplates.VARIABLES.forEach { variable ->
            val token = ScheduleTemplates.token(variable)
            AssistChip(
                onClick = { onInsert(variable) },
                label = { Text(token, fontSize = 11.sp) },
                modifier = Modifier.semantics { contentDescription = "$token, ${ScheduleTemplates.help(variable)}" },
            )
        }
    }
}

/** The example's values: the next occurrence in [preview] (else now), its date in the schedule's zone, and the chosen names. */
private fun scheduleExampleValues(preview: List<String>, projectName: String?, scheduleName: String, boardName: String?, timezone: String): Map<String, String> {
    val instant = preview.firstOrNull()?.let { runCatching { Instant.parse(it) }.getOrNull() } ?: Instant.now()
    val zone = runCatching { ZoneId.of(timezone) }.getOrElse { ZoneId.systemDefault() }
    return ScheduleTemplates.exampleValues(projectName, boardName, scheduleName, instant.toString(), DateTimeFormatter.ISO_LOCAL_DATE.format(instant.atZone(zone)))
}
