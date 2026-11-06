@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.getdieter.mobile.tools

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
import com.getdieter.api.v1.ScheduleDraft
import com.getdieter.client.v1.*
import com.getdieter.core.schedules.Cadence
import com.getdieter.core.schedules.CadenceKind
import com.getdieter.core.schedules.ScheduleDrafts
import com.getdieter.core.schedules.ScheduleTemplates
import com.getdieter.mobile.app.*
import com.getdieter.mobile.creation.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.design.Tone
import com.getdieter.mobile.store.*

@Composable
internal fun SchedulesScreen(store: MobileStore, projectId: String) {
    val view by store.schedules.slice.collectAsState()
    val workspace by store.workspace.slice.collectAsState()
    var editorId by remember { mutableStateOf<String?>(null) }
    var deleteId by remember { mutableStateOf("") }
    fun command(value: SchedulesCommand) =
        store.command(Command(schedules = value.copy(scope = MobileStore.SCHEDULES_SCOPE)))
    val project = workspace.projects.firstOrNull { it.id == projectId }
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
                                )
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
    val workspace by store.workspace.slice.collectAsState()
    val preview by store.creation.preview.collectAsState()
    val schedules by store.schedules.slice.collectAsState()
    val busy by store.busy.collectAsState()
    var draft by remember(scheduleId) { mutableStateOf<ScheduleDraft?>(null) }
    LaunchedEffect(scheduleId) {
        store.action {
            store.creation.chat.value = false
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
                                            selected_board_id = store.boards.selectedBoard.value,
                                            timezone = "UTC",
                                        ),
                                )
                        )
                    )
                    .schedule_draft
            draft?.let {
                store.creation.update(
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
        AgentSettings(preview.agent) { choice ->
            store.creation.update(store.creation.intent.value, choice)
        }
        SectionHeader("Behavior")
        Group(listOf(0, 1, 2, 3, 4)) { index, position ->
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
                4 ->
                    ListRow(
                        "Allow mail",
                        position = position,
                        subtitle = "Runs may send you reports",
                        trailing = {
                            DSwitch(
                                value.mail_access,
                                { draft = value.copy(mail_access = it) },
                                Modifier.testTag("schedule-mail-access"),
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
