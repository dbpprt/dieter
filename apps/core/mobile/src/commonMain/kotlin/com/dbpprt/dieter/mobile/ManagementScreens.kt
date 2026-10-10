@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.dbpprt.dieter.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.api.v1.ScheduleDraft
import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.core.schedules.Cadence
import com.dbpprt.dieter.core.schedules.CadenceKind
import com.dbpprt.dieter.core.schedules.ScheduleDrafts
import com.dbpprt.dieter.core.schedules.ScheduleTemplates

/** A padded form column used inside sheets. */
@Composable
internal fun FormColumn(content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
        content = content,
    )
}

@Composable
internal fun ProjectEditor(store: MobileStore, onDismiss: () -> Unit) {
    val session by store.session.collectAsState()
    val busy by store.busy.collectAsState()
    var name by remember { mutableStateOf("") }
    var path by remember { mutableStateOf("") }
    var machine by remember { mutableStateOf("") }
    var create by remember { mutableStateOf(false) }
    var review by remember { mutableStateOf(true) }
    val machines = session.machines.filter { it.available }
    Sheet(
        "New Project",
        onDismiss,
        confirm =
            ChromeAction(
                "create-project",
                "Create",
                Glyph.CHECK,
                enabled = name.isNotBlank() && path.isNotBlank() && machine.isNotBlank() && !busy,
            ) {
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
                                                workflow = if (review) "review" else "direct",
                                            )
                                    )
                            )
                        )
                    onDismiss()
                    result.created_project?.board?.let { store.push(MobileRoute.Board(it.id)) }
                }
            },
    ) {
        Group(listOf(0)) { _, position ->
            PickerRow(
                "Machine",
                machines.firstOrNull { it.id == machine }?.display_name.orEmpty(),
                machines.map { it.id to it.display_name },
                machine,
                machines.isNotEmpty(),
                position,
                Glyph.MACHINE,
            ) {
                machine = it
            }
        }
        Spacer(Modifier.height(16.dp))
        FormColumn {
            MobileTextField(
                name,
                { name = it },
                Modifier.fillMaxWidth().testTag("project-name"),
                label = { Text("Name") },
                placeholder = { Text("Project name") },
                singleLine = true,
            )
            MobileTextField(
                path,
                { path = it },
                Modifier.fillMaxWidth().testTag("project-path"),
                label = { Text("Path") },
                placeholder = { Text("Repository path on the machine") },
                singleLine = true,
            )
        }
        SectionHeader("Options")
        Group(listOf(0, 1)) { index, position ->
            if (index == 0)
                ListRow(
                    "Create a new Git repository",
                    position = position,
                    trailing = { DSwitch(create, { create = it }) },
                )
            else
                ListRow(
                    "Review before merging",
                    position = position,
                    subtitle = "Cards move to Review before Done",
                    trailing = { DSwitch(review, { review = it }) },
                )
        }
    }
}

@Composable
internal fun TerminalEditor(store: MobileStore, onDismiss: () -> Unit) {
    val session by store.session.collectAsState()
    val workspace by store.workspace.collectAsState()
    val busy by store.busy.collectAsState()
    var machine by remember {
        mutableStateOf(session.machines.firstOrNull { it.available }?.id.orEmpty())
    }
    var checkout by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    var shell by remember { mutableStateOf("") }
    val checkouts =
        workspace.projects.flatMap { project ->
            project.checkouts.filter { it.daemon_id == machine }.map { it to project }
        }
    Sheet(
        "New Terminal",
        onDismiss,
        confirm =
            ChromeAction(
                "create-terminal",
                "Create",
                Glyph.CHECK,
                enabled = machine.isNotEmpty() && !busy,
            ) {
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
                                            machine_home = checkout.isEmpty(),
                                            project_id = project?.id.orEmpty(),
                                            checkout_id = checkout,
                                            name = name,
                                            shell = shell,
                                        ),
                                )
                        )
                    )
                    onDismiss()
                }
            },
    ) {
        val machines = session.machines.filter { it.available }
        Group(listOf(0, 1)) { index, position ->
            if (index == 0)
                PickerRow(
                    "Machine",
                    machines.firstOrNull { it.id == machine }?.display_name.orEmpty(),
                    machines.map { it.id to it.display_name },
                    machine,
                    machines.isNotEmpty(),
                    position,
                    Glyph.MACHINE,
                ) {
                    machine = it
                    checkout = ""
                }
            else
                PickerRow(
                    "Directory",
                    checkouts
                        .firstOrNull { it.first.id == checkout }
                        ?.let { it.second.name + " · " + it.first.name } ?: "Home folder",
                    listOf("" to "Home folder") +
                        checkouts.map { it.first.id to (it.second.name + " · " + it.first.name) },
                    checkout,
                    machine.isNotEmpty(),
                    position,
                    Glyph.FOLDER,
                ) {
                    checkout = it
                }
        }
        Spacer(Modifier.height(16.dp))
        FormColumn {
            MobileTextField(
                name,
                { name = it },
                Modifier.fillMaxWidth(),
                label = { Text("Name") },
                placeholder = { Text("Terminal name (optional)") },
                singleLine = true,
            )
            MobileTextField(
                shell,
                { shell = it },
                Modifier.fillMaxWidth(),
                label = { Text("Shell") },
                placeholder = { Text("Shell (machine default)") },
                singleLine = true,
            )
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Schedules
// ---------------------------------------------------------------------------------------------

@Composable
internal fun SchedulesScreen(store: MobileStore) {
    val view by store.schedules.collectAsState()
    val workspace by store.workspace.collectAsState()
    var editorId by remember { mutableStateOf<String?>(null) }
    var deleteId by remember { mutableStateOf("") }
    fun command(value: SchedulesCommand) =
        store.command(Command(schedules = value.copy(scope = MobileStore.SCHEDULES_SCOPE)))
    fun rebind() {
        val projectId = store.currentProjectId()
        store.action {
            store.core.dispatch(
                Command(
                    schedules =
                        SchedulesCommand(
                            scope = MobileStore.SCHEDULES_SCOPE,
                            bind = ScheduleProject(projectId),
                        )
                )
            )
            store.core.dispatch(
                Command(
                    schedules = SchedulesCommand(scope = MobileStore.SCHEDULES_SCOPE, load = Step())
                )
            )
        }
    }
    val project = workspace.projects.firstOrNull { it.id == store.currentProjectId() }
    Screen(
        ScreenChrome(
            "Schedules",
            subtitle = project?.name.orEmpty(),
            actions =
                listOf(
                    ChromeAction(
                        "schedules-menu",
                        "Schedule options",
                        Glyph.MORE_HORIZONTAL,
                        menu =
                            listOf(
                                MenuSection(
                                    listOf(
                                        ChromeAction(
                                            "refresh-schedules",
                                            "Refresh",
                                            Glyph.REFRESH,
                                        ) {
                                            command(SchedulesCommand(load = Step()))
                                        }
                                    )
                                ),
                                MenuSection(projectScopeMenu(store, ::rebind).take(1)),
                            ),
                    ),
                    ChromeAction("new-schedule", "New schedule", Glyph.ADD) { editorId = "" },
                ),
        )
    ) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("schedules-list"),
            state = listState,
            contentPadding = padding,
        ) {
            if (view.error.isNotEmpty())
                item {
                    Banner(
                        "Schedules unavailable",
                        view.error,
                        Modifier.padding(horizontal = ScreenMargin, vertical = 8.dp),
                        tone = Tone.WARNING,
                        actionLabel = "Retry",
                        onAction = { command(SchedulesCommand(load = Step())) },
                    )
                }
            if (view.action_error.isNotEmpty())
                item {
                    Banner(
                        "Action failed",
                        view.action_error,
                        Modifier.padding(horizontal = ScreenMargin, vertical = 8.dp),
                        tone = Tone.DANGER,
                    )
                }
            item { Spacer(Modifier.height(8.dp)) }
            if (view.loading && view.schedules.isEmpty())
                item {
                    Box(
                        Modifier.fillMaxWidth().padding(40.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Spinner(Modifier.size(24.dp))
                    }
                }
            if (view.loaded && view.schedules.isEmpty())
                item {
                    EmptyState(
                        Glyph.SCHEDULES,
                        "No schedules",
                        "Create cards or chats automatically on a schedule.",
                        Modifier.padding(top = 32.dp),
                    ) {
                        DButton("New schedule", { editorId = "" }, glyph = Glyph.ADD)
                    }
                }
            itemsIndexed(view.schedules, key = { _, schedule -> schedule.id }) { _, schedule ->
                val row = view.rows.firstOrNull { it.id == schedule.id }
                val menu = rememberMenuState()
                val sections =
                    listOf(
                        MenuSection(
                            listOf(
                                ChromeAction("run-${schedule.id}", "Run now", Glyph.PLAY) {
                                    command(SchedulesCommand(run_now = ScheduleId(schedule.id)))
                                },
                                ChromeAction(
                                    "history-${schedule.id}",
                                    "Run history",
                                    Glyph.HISTORY,
                                ) {
                                    command(SchedulesCommand(select = ScheduleId(schedule.id)))
                                },
                                ChromeAction("edit-${schedule.id}", "Edit…", Glyph.EDIT) {
                                    editorId = schedule.id
                                },
                            )
                        ),
                        MenuSection(
                            listOf(
                                ChromeAction(
                                    "delete-${schedule.id}",
                                    "Delete",
                                    Glyph.TRASH,
                                    destructive = true,
                                ) {
                                    deleteId = schedule.id
                                }
                            )
                        ),
                    )
                MenuAnchor(menu) {
                    ContentCard(
                        Modifier.padding(horizontal = ScreenMargin, vertical = 5.dp)
                            .testTag("schedule-${schedule.id}"),
                        onClick = { editorId = schedule.id },
                        onLongClick = { menu.show(sections) },
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(
                                    schedule.name,
                                    style = type.headline,
                                    color = palette.label,
                                    maxLines = 2,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Text(
                                    row?.timing.orEmpty(),
                                    style = type.subheadline,
                                    color = palette.secondaryLabel,
                                )
                            }
                            DSwitch(
                                schedule.enabled,
                                {
                                    command(
                                        SchedulesCommand(
                                            set_enabled = ScheduleEnabled(schedule.id, it)
                                        )
                                    )
                                },
                            )
                        }
                        if (!row?.subtitle.isNullOrEmpty()) {
                            Spacer(Modifier.height(6.dp))
                            Text(
                                row.subtitle,
                                style = type.subheadline,
                                color = palette.label,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        Spacer(Modifier.height(8.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                listOf(row?.placement.orEmpty(), row?.status.orEmpty())
                                    .filter { it.isNotEmpty() }
                                    .joinToString(" · "),
                                Modifier.weight(1f),
                                style = type.footnote,
                                color = palette.secondaryLabel,
                            )
                            MenuButton(sections, "Schedule actions")
                        }
                    }
                }
            }
            if (view.next_page_token.isNotEmpty())
                item {
                    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                        DButton(
                            "Load more",
                            { command(SchedulesCommand(load_more = Step())) },
                            kind = ButtonKind.PLAIN,
                        )
                    }
                }
            if (view.selected_id.isNotEmpty()) {
                item {
                    SectionHeader(
                        "Run history",
                        trailing = {
                            DButton(
                                "Hide",
                                { command(SchedulesCommand(select = ScheduleId(""))) },
                                kind = ButtonKind.PLAIN,
                            )
                        },
                    )
                }
                if (view.runs_loading && view.run_rows.isEmpty())
                    item {
                        Box(
                            Modifier.fillMaxWidth().padding(24.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            Spinner()
                        }
                    }
                else if (view.run_rows.isEmpty())
                    item { SectionFooter("This schedule has not run yet.") }
                itemsIndexed(view.run_rows, key = { _, run -> run.id }) { index, run ->
                    ListRow(
                        run.status,
                        position = Position.of(index, view.run_rows.size),
                        subtitle =
                            listOf(run.at, run.trigger, run.message)
                                .filter { it.isNotEmpty() }
                                .joinToString(" · "),
                        accessory =
                            if (run.card_id.isNotEmpty()) Accessory.CHEVRON else Accessory.NONE,
                        onClick =
                            if (run.card_id.isNotEmpty()) ({ store.openConversation(run.card_id) })
                            else null,
                        subtitleMaxLines = 3,
                    )
                }
                if (view.runs_next_page_token.isNotEmpty())
                    item {
                        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                            DButton(
                                "Load older runs",
                                { command(SchedulesCommand(load_more_runs = Step())) },
                                kind = ButtonKind.PLAIN,
                            )
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
        ConfirmDialog(
            "Delete schedule?",
            "Conversations it created remain available.",
            "Delete",
            {
                command(SchedulesCommand(delete = ScheduleId(deleteId)))
                deleteId = ""
            },
            { deleteId = "" },
            destructive = true,
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
    val value = draft
    Sheet(
        if (scheduleId.isEmpty()) "New Schedule" else "Edit Schedule",
        onDismiss,
        confirm =
            ChromeAction(
                "save-schedule",
                "Save",
                Glyph.CHECK,
                enabled = value != null && ScheduleDrafts.canSave(value) && !busy,
            ) {
                val current = draft ?: return@ChromeAction
                store.action {
                    store.core.dispatch(
                        Command(
                            schedules =
                                SchedulesCommand(
                                    scope = MobileStore.SCHEDULES_SCOPE,
                                    save = SaveSchedule(current, scheduleId, current.checkout_id),
                                )
                        )
                    )
                    onDismiss()
                }
            },
    ) {
        if (value == null) {
            Box(Modifier.fillMaxWidth().height(160.dp), contentAlignment = Alignment.Center) {
                Spinner(Modifier.size(24.dp))
            }
            return@Sheet
        }
        FormColumn {
            MobileTextField(
                value.name,
                { draft = value.copy(name = it) },
                Modifier.fillMaxWidth().testTag("schedule-name"),
                label = { Text("Name") },
                placeholder = { Text("Schedule name") },
                singleLine = true,
            )
        }
        SectionHeader("Destination")
        val project = workspace.projects.firstOrNull { it.id == value.project_id }
        val boards = workspace.boards.filter { it.project_id == value.project_id }
        Group(listOf(0, 1)) { index, position ->
            if (index == 0)
                PickerRow(
                    "Board",
                    boards.firstOrNull { it.id == value.board_id }?.name.orEmpty(),
                    boards.map { it.id to it.name },
                    value.board_id,
                    boards.isNotEmpty(),
                    position,
                    Glyph.BOARD,
                ) { board ->
                    workspace.boards
                        .firstOrNull { it.id == board }
                        ?.let { draft = ScheduleDrafts.onBoard(value, it) }
                }
            else
                PickerRow(
                    "Checkout",
                    project?.checkouts?.firstOrNull { it.id == value.checkout_id }?.name.orEmpty(),
                    project?.checkouts.orEmpty().map { it.id to it.name },
                    value.checkout_id,
                    true,
                    position,
                    Glyph.MACHINE,
                ) {
                    draft = value.copy(checkout_id = it)
                }
        }
        SectionHeader("Timing")
        val cadence = Cadence.parse(value.cron)
        Group(listOf(0)) { _, position ->
            PickerRow(
                "Repeat",
                cadence.kind.title,
                CadenceKind.entries.map { it.name to it.title },
                cadence.kind.name,
                true,
                position,
                Glyph.CLOCK,
            ) {
                draft = value.copy(cron = cadence.withKind(CadenceKind.valueOf(it)).cron())
            }
        }
        FormColumn {
            MobileTextField(
                value.cron,
                { draft = value.copy(cron = it) },
                Modifier.fillMaxWidth(),
                label = { Text("Cron expression") },
                placeholder = { Text("Cron expression") },
                supportingText = { Text(ScheduleDrafts.CRON_HELP) },
                singleLine = true,
            )
            MobileTextField(
                value.timezone,
                { draft = value.copy(timezone = it) },
                Modifier.fillMaxWidth(),
                label = { Text("Time zone") },
                placeholder = { Text("Time zone") },
                singleLine = true,
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
                Text(schedules.preview_error, style = type.footnote, color = palette.destructive)
            if (schedules.preview.isNotEmpty())
                Column(
                    Modifier.fillMaxWidth()
                        .clip(groupShape(Position.SINGLE))
                        .background(palette.cell)
                        .padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(
                        "Next runs",
                        style = type.footnote.copy(fontWeight = FontWeight.SemiBold),
                        color = palette.secondaryLabel,
                    )
                    schedules.preview.forEach {
                        Text(it, style = type.subheadline, color = palette.label)
                    }
                }
        }
        SectionHeader("Card")
        FormColumn {
            MobileTextField(
                value.title_template,
                { draft = value.copy(title_template = it) },
                Modifier.fillMaxWidth(),
                label = { Text("Title template") },
                placeholder = { Text("Title template") },
                singleLine = true,
            )
            MobileTextField(
                value.prompt_template,
                { draft = value.copy(prompt_template = it) },
                Modifier.fillMaxWidth(),
                label = { Text("Task template") },
                placeholder = { Text("What should the agent do?") },
                minLines = 3,
            )
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                ScheduleTemplates.VARIABLES.forEach { variable ->
                    FilterPill(
                        ScheduleTemplates.token(variable),
                        false,
                        {
                            draft =
                                value.copy(
                                    prompt_template =
                                        ScheduleTemplates.insert(value.prompt_template, variable)
                                )
                        },
                    )
                }
            }
        }
        SectionHeader("Agent")
        AgentSettings(preview.agent) { choice -> store.preview(store.creationIntent.value, choice) }
        SectionHeader("Behavior")
        Group(listOf(0, 1, 2, 3)) { index, position ->
            when (index) {
                0 ->
                    PickerRow(
                        "Place in",
                        ScheduleDrafts.placementTitle(value.action),
                        listOf("draft" to "Todo", "run" to "Running"),
                        value.action,
                        true,
                        position,
                    ) {
                        draft = value.copy(action = it)
                    }
                1 ->
                    PickerRow(
                        "When a card is open",
                        if (value.open_card_policy == "always") "Always create" else "Skip",
                        listOf("skip_if_open" to "Skip", "always" to "Always create"),
                        value.open_card_policy,
                        true,
                        position,
                    ) {
                        draft = value.copy(open_card_policy = it)
                    }
                3 ->
                    ListRow(
                        "Vault access",
                        position = position,
                        subtitle = "Its cards may use the account's passwords and TOTP codes",
                        trailing = {
                            DSwitch(
                                value.vault_access,
                                { draft = value.copy(vault_access = it) },
                                Modifier.testTag("schedule-vault-access"),
                            )
                        },
                    )
                else ->
                    PickerRow(
                        "Workspace",
                        if (value.workspace_mode == "worktree") "New worktree"
                        else "Project directory",
                        listOf("worktree" to "New worktree", "project" to "Project directory"),
                        value.workspace_mode,
                        true,
                        position,
                    ) {
                        draft = value.copy(workspace_mode = it)
                    }
            }
        }
        SectionFooter(ScheduleDrafts.MISFIRE_NOTE)
    }
}
