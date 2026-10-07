@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.mobile

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.api.v1.ScheduleDraft
import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.core.schedules.Cadence
import com.dbpprt.dieter.core.schedules.CadenceKind
import com.dbpprt.dieter.core.schedules.ScheduleDrafts
import com.dbpprt.dieter.core.schedules.ScheduleTemplates
import com.dbpprt.dieter.mobile.icons.*

@Composable
internal fun ProjectEditor(store: MobileStore, onDismiss: () -> Unit) {
    val session by store.session.collectAsState()
    val busy by store.busy.collectAsState()
    var name by remember { mutableStateOf("") }
    var path by remember { mutableStateOf("") }
    var machine by remember { mutableStateOf("") }
    var create by remember { mutableStateOf(false) }
    var workflow by remember { mutableStateOf("review") }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            Modifier.imePadding().verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("New project", style = MaterialTheme.typography.titleLarge)
            ChoiceChip(
                session.machines.firstOrNull { it.id == machine }?.display_name
                    ?: "Choose a machine",
                session.machines.filter { it.available }.map { it.id to it.display_name },
            ) {
                machine = it
            }
            MobileTextField(
                name,
                { name = it },
                label = { Text("Project name") },
                modifier = Modifier.fillMaxWidth(),
            )
            MobileTextField(
                path,
                { path = it },
                label = { Text("Repository path on the machine") },
                modifier = Modifier.fillMaxWidth(),
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Checkbox(create, { create = it })
                Text("Create a new Git repository")
            }
            ChoiceChip(
                workflow.replaceFirstChar(Char::uppercase),
                listOf("review" to "Review", "direct" to "Direct"),
            ) {
                workflow = it
            }
            Button(
                onClick = {
                    store.action {
                        val result =
                            store.core.dispatch(
                                Command(
                                    admin =
                                        AdminCommand(
                                            create_project =
                                                AdminCreateProject(
                                                    daemon_id = machine,
                                                    path = path,
                                                    name = name,
                                                    create = create,
                                                    board_name = "Main",
                                                    workflow = workflow,
                                                )
                                        )
                                )
                            )
                        result.created_project?.board?.let {
                            store.chooseBoard(it.id)
                            store.tab.value = MobileTab.BOARD
                        }
                        onDismiss()
                    }
                },
                enabled = name.isNotBlank() && path.isNotBlank() && machine.isNotBlank() && !busy,
            ) {
                Text("Create project")
            }
        }
    }
}

@Composable
internal fun TerminalEditor(store: MobileStore, onDismiss: () -> Unit) {
    val session by store.session.collectAsState()
    val workspace by store.workspace.collectAsState()
    val busy by store.busy.collectAsState()
    var machine by remember { mutableStateOf("") }
    var checkout by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    var shell by remember { mutableStateOf("") }
    var home by remember { mutableStateOf(true) }
    val checkouts =
        workspace.projects.flatMap { project ->
            project.checkouts.filter { it.daemon_id == machine }.map { it to project }
        }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            Modifier.imePadding().verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("New terminal", style = MaterialTheme.typography.titleLarge)
            ChoiceChip(
                session.machines.firstOrNull { it.id == machine }?.display_name ?: "Choose machine",
                session.machines.filter { it.available }.map { it.id to it.display_name },
            ) {
                machine = it
                checkout = ""
            }
            MobileTextField(
                name,
                { name = it },
                label = { Text("Terminal name") },
                modifier = Modifier.fillMaxWidth(),
            )
            MobileTextField(
                shell,
                { shell = it },
                label = { Text("Shell (machine default if empty)") },
                modifier = Modifier.fillMaxWidth(),
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Checkbox(home, { home = it })
                Text("Machine home directory")
            }
            if (!home)
                ChoiceChip(
                    checkouts
                        .firstOrNull { it.first.id == checkout }
                        ?.let { it.second.name + " · " + it.first.name } ?: "Choose checkout",
                    checkouts.map { it.first.id to (it.second.name + " · " + it.first.name) },
                ) {
                    checkout = it
                }
            Button(
                onClick = {
                    store.action {
                        val project = checkouts.firstOrNull { it.first.id == checkout }?.second
                        store.core.dispatch(
                            Command(
                                terminal_overview =
                                    TerminalOverviewCommand(
                                        scope = MobileStore.TERMINAL_SCOPE,
                                        create =
                                            CreateOverviewTerminal(
                                                daemon_id = machine,
                                                machine_home = home,
                                                project_id =
                                                    if (home) "" else project?.id.orEmpty(),
                                                checkout_id = if (home) "" else checkout,
                                                name = name,
                                                shell = shell,
                                            ),
                                    )
                            )
                        )
                        onDismiss()
                    }
                },
                enabled = machine.isNotEmpty() && (home || checkout.isNotEmpty()) && !busy,
            ) {
                Text("Create terminal")
            }
        }
    }
}

@Composable
internal fun SchedulesScreen(store: MobileStore) {
    val view by store.schedules.collectAsState()
    var editorId by remember { mutableStateOf<String?>(null) }
    var deleteId by remember { mutableStateOf("") }
    fun command(value: SchedulesCommand) =
        store.command(Command(schedules = value.copy(scope = MobileStore.SCHEDULES_SCOPE)))
    Column {
        PageHeader("Schedules", view.subtitle, back = { store.navigate(MobileTab.TOOLS) }) {
            IconButton(onClick = { command(SchedulesCommand(load = Step())) }) {
                Icon(Icons.Outlined.Refresh, "Refresh schedules")
            }
            IconButton(onClick = { editorId = "" }) { Icon(Icons.Outlined.Add, "New schedule") }
        }
        ProjectSelector(store)
        if (view.error.isNotEmpty())
            Notice(
                "Schedules unavailable",
                view.error,
                { command(SchedulesCommand(load = Step())) },
            )
        if (view.action_error.isNotEmpty())
            Text(view.action_error, color = colors.error, modifier = Modifier.padding(16.dp))
        LazyColumn(
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(view.schedules, key = { it.id }) { schedule ->
                val row = view.rows.firstOrNull { it.id == schedule.id }
                FormSection(schedule.name) {
                    Text(row?.timing.orEmpty(), style = MaterialTheme.typography.bodySmall)
                    Text(row?.subtitle.orEmpty(), style = MaterialTheme.typography.bodyMedium)
                    Text(
                        "${row?.placement.orEmpty()} · ${row?.status.orEmpty()}",
                        style = MaterialTheme.typography.labelSmall,
                        color = colors.onSurfaceVariant,
                    )
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Switch(
                            schedule.enabled,
                            {
                                command(
                                    SchedulesCommand(set_enabled = ScheduleEnabled(schedule.id, it))
                                )
                            },
                        )
                        TextButton(onClick = { editorId = schedule.id }) { Text("Edit") }
                        TextButton(
                            onClick = {
                                command(SchedulesCommand(run_now = ScheduleId(schedule.id)))
                            }
                        ) {
                            Text("Run now")
                        }
                        IconButton(
                            onClick = {
                                command(SchedulesCommand(select = ScheduleId(schedule.id)))
                            }
                        ) {
                            Icon(Icons.Outlined.History, "Run history")
                        }
                        IconButton(onClick = { deleteId = schedule.id }) {
                            Icon(Icons.Outlined.Delete, "Delete schedule")
                        }
                    }
                }
            }
            if (view.loading) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            if (view.loaded && view.schedules.isEmpty())
                item {
                    Box(Modifier.height(200.dp)) {
                        Empty("No schedules", "Automate cards and chats with cron schedules.")
                    }
                }
            if (view.next_page_token.isNotEmpty())
                item {
                    TextButton(onClick = { command(SchedulesCommand(load_more = Step())) }) {
                        Text("Load more schedules")
                    }
                }
            if (view.selected_id.isNotEmpty()) {
                item { Text("Run history", style = MaterialTheme.typography.titleMedium) }
                items(view.run_rows, key = { it.id }) { run ->
                    ListItem(
                        headlineContent = { Text(run.status + " · " + run.trigger) },
                        supportingContent = { Text(run.at + "\n" + run.message) },
                        modifier =
                            Modifier.clickable(enabled = run.card_id.isNotEmpty()) {
                                store.openCard(run.card_id)
                            },
                    )
                }
                if (view.runs_loading) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
                if (view.runs_next_page_token.isNotEmpty())
                    item {
                        TextButton(
                            onClick = { command(SchedulesCommand(load_more_runs = Step())) }
                        ) {
                            Text("Load older runs")
                        }
                    }
            }
        }
    }
    editorId?.let { id ->
        ScheduleEditor(store, id) {
            editorId = null
            command(SchedulesCommand(close_editor = Step()))
        }
    }
    if (deleteId.isNotEmpty())
        AlertDialog(
            onDismissRequest = { deleteId = "" },
            title = { Text("Delete schedule?") },
            text = { Text("Existing conversations remain available.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        command(SchedulesCommand(delete = ScheduleId(deleteId)))
                        deleteId = ""
                    }
                ) {
                    Text("Delete")
                }
            },
            dismissButton = { TextButton(onClick = { deleteId = "" }) { Text("Cancel") } },
        )
}

@Composable
private fun ScheduleEditor(store: MobileStore, scheduleId: String, onDismiss: () -> Unit) {
    val workspace by store.workspace.collectAsState()
    val preview by store.creationPreview.collectAsState()
    val schedules by store.schedules.collectAsState()
    val busy by store.busy.collectAsState()
    var draft by remember(scheduleId) { mutableStateOf<ScheduleDraft?>(null) }
    LaunchedEffect(scheduleId) {
        store.action {
            store.creatingChat.value = false
            draft =
                store.core
                    .dispatch(
                        Command(
                            schedules =
                                SchedulesCommand(
                                    scope = MobileStore.SCHEDULES_SCOPE,
                                    draft =
                                        ScheduleDraftRequest(
                                            schedule_id = scheduleId,
                                            selected_board_id = store.selectedBoard.value,
                                            timezone = "UTC",
                                        ),
                                )
                        )
                    )
                    .schedule_draft
            draft?.let {
                store.preview(
                    CreationIntent(
                        project_id = it.project_id,
                        board_id = it.board_id,
                        checkout_id = it.checkout_id,
                        selection = ScheduleDrafts.selection(it),
                    )
                )
            }
        }
    }
    LaunchedEffect(preview.agent?.selection) {
        preview.agent?.selection?.let { selection ->
            draft = draft?.let { ScheduleDrafts.choose(it, selection) }
        }
    }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        val value = draft
        if (value == null)
            Box(Modifier.fillMaxWidth().height(120.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
        else
            Column(
                Modifier.imePadding().verticalScroll(rememberScrollState()).padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(
                    if (scheduleId.isEmpty()) "New schedule" else "Edit schedule",
                    style = MaterialTheme.typography.titleLarge,
                )
                MobileTextField(
                    value.name,
                    { draft = value.copy(name = it) },
                    label = { Text("Schedule name") },
                    modifier = Modifier.fillMaxWidth(),
                )
                val project = workspace.projects.firstOrNull { it.id == value.project_id }
                ChoiceChip(
                    workspace.boards.firstOrNull { it.id == value.board_id }?.name
                        ?: "Choose board",
                    workspace.boards
                        .filter { it.project_id == value.project_id }
                        .map { it.id to it.name },
                ) { board ->
                    workspace.boards
                        .firstOrNull { it.id == board }
                        ?.let { draft = ScheduleDrafts.onBoard(value, it) }
                }
                ChoiceChip(
                    project?.checkouts?.firstOrNull { it.id == value.checkout_id }?.name
                        ?: "Choose checkout",
                    project?.checkouts.orEmpty().map { it.id to it.name },
                ) {
                    draft = value.copy(checkout_id = it)
                }
                val cadence = Cadence.parse(value.cron)
                ChoiceChip(cadence.kind.title, CadenceKind.entries.map { it.name to it.title }) {
                    draft = value.copy(cron = cadence.withKind(CadenceKind.valueOf(it)).cron())
                }
                MobileTextField(
                    value.cron,
                    { draft = value.copy(cron = it) },
                    label = { Text("Cron expression") },
                    supportingText = { Text(ScheduleDrafts.CRON_HELP) },
                    modifier = Modifier.fillMaxWidth(),
                )
                MobileTextField(
                    value.timezone,
                    { draft = value.copy(timezone = it) },
                    label = { Text("Time zone") },
                    modifier = Modifier.fillMaxWidth(),
                )
                LaunchedEffect(value.cron, value.timezone) {
                    store.command(
                        Command(
                            schedules =
                                SchedulesCommand(
                                    scope = MobileStore.SCHEDULES_SCOPE,
                                    preview = SchedulePreview(value.cron, value.timezone),
                                )
                        )
                    )
                }
                if (schedules.preview_error.isNotEmpty())
                    Text(schedules.preview_error, color = colors.error)
                if (schedules.preview.isNotEmpty())
                    Text(
                        "Next runs\n" + schedules.preview.joinToString("\n"),
                        style = MaterialTheme.typography.bodySmall,
                    )
                MobileTextField(
                    value.title_template,
                    { draft = value.copy(title_template = it) },
                    label = { Text("Card title template") },
                    modifier = Modifier.fillMaxWidth(),
                )
                MobileTextField(
                    value.prompt_template,
                    { draft = value.copy(prompt_template = it) },
                    label = { Text("Agent task template") },
                    modifier = Modifier.fillMaxWidth(),
                    minLines = 3,
                )
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    ScheduleTemplates.VARIABLES.forEach { variable ->
                        AssistChip(
                            onClick = {
                                draft =
                                    value.copy(
                                        prompt_template =
                                            ScheduleTemplates.insert(
                                                value.prompt_template,
                                                variable,
                                            )
                                    )
                            },
                            label = { Text(ScheduleTemplates.token(variable)) },
                        )
                    }
                }
                AgentSettings(preview.agent) { choice ->
                    store.preview(store.creationIntent.value, choice)
                }
                ChoiceChip(
                    ScheduleDrafts.placementTitle(value.action),
                    listOf("draft" to "Todo", "run" to "Running"),
                ) {
                    draft = value.copy(action = it)
                }
                ChoiceChip(
                    if (value.open_card_policy == "always") "Always create" else "Skip if open",
                    listOf("skip_if_open" to "Skip if open", "always" to "Always create"),
                ) {
                    draft = value.copy(open_card_policy = it)
                }
                ChoiceChip(
                    value.workspace_mode.replaceFirstChar(Char::uppercase),
                    listOf("worktree" to "Worktree", "project" to "Project"),
                ) {
                    draft = value.copy(workspace_mode = it)
                }
                Text(
                    ScheduleDrafts.MISFIRE_NOTE,
                    style = MaterialTheme.typography.bodySmall,
                    color = colors.onSurfaceVariant,
                )
                Button(
                    onClick = {
                        store.action {
                            store.core.dispatch(
                                Command(
                                    schedules =
                                        SchedulesCommand(
                                            scope = MobileStore.SCHEDULES_SCOPE,
                                            save =
                                                SaveSchedule(value, scheduleId, value.checkout_id),
                                        )
                                )
                            )
                            onDismiss()
                        }
                    },
                    enabled = ScheduleDrafts.canSave(value) && !busy,
                ) {
                    Text("Save schedule")
                }
            }
    }
}
