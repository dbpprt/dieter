package com.dbpprt.dieter.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.core.workspace.GitOperations

@Composable
internal fun ProjectChangesScreen(store: MobileStore) {
    val view by store.projectChanges.collectAsState()
    val workspace by store.workspace.collectAsState()
    var operation by remember { mutableStateOf<String?>(null) }
    fun send(value: ProjectChangesCommand) =
        store.command(
            Command(project_changes = value.copy(scope = MobileStore.PROJECT_CHANGES_SCOPE))
        )
    DisposableEffect(store) {
        send(ProjectChangesCommand(active = Toggle(true)))
        onDispose { send(ProjectChangesCommand(active = Toggle(false))) }
    }
    val project = workspace.projects.firstOrNull { it.id == store.currentProjectId() }
    val files = view.changes?.files.orEmpty()
    val selected = view.selection?.path.orEmpty()
    val chrome =
        ScreenChrome(
            "Changes",
            subtitle =
                listOfNotNull(project?.name, view.changes?.branch?.takeIf { it.isNotEmpty() })
                    .joinToString(" · "),
            actions =
                listOf(
                    ChromeAction(
                        "changes-menu",
                        "Git actions",
                        Glyph.MORE_HORIZONTAL,
                        menu =
                            listOfNotNull(
                                if (view.allowed.isNotEmpty())
                                    MenuSection(
                                        view.allowed
                                            .filter { it != "stage" && it != "unstage" }
                                            .map { kind ->
                                                ChromeAction(
                                                    "git-$kind",
                                                    GitOperations.title(kind),
                                                    gitGlyph(kind),
                                                    enabled = !view.mutations_disabled,
                                                ) {
                                                    operation = kind
                                                }
                                            }
                                    )
                                else null,
                                MenuSection(
                                    listOf(
                                        ChromeAction(
                                            "split",
                                            "Side-by-side diff",
                                            Glyph.CHANGES,
                                            checked = view.split,
                                        ) {
                                            send(
                                                ProjectChangesCommand(
                                                    layout = ReviewLayout(!view.split)
                                                )
                                            )
                                        },
                                        ChromeAction("refresh-changes", "Refresh", Glyph.REFRESH) {
                                            send(ProjectChangesCommand(refresh = Step()))
                                        },
                                    )
                                ),
                                MenuSection(projectScopeMenu(store) { store.bindProjectChanges() }),
                            ),
                    )
                ),
        )
    Screen(chrome) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("project-changes"),
            state = listState,
            contentPadding = padding,
        ) {
            item { Spacer(Modifier.height(4.dp)) }
            listOf(view.refresh_error, view.diff_error, view.operation_error)
                .filter { it.isNotEmpty() }
                .forEach { failure ->
                    item {
                        Banner(
                            "Changes unavailable",
                            failure,
                            Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                            tone = Tone.DANGER,
                            actionLabel = "Retry",
                            onAction = { send(ProjectChangesCommand(refresh = Step())) },
                        )
                    }
                }
            if (view.notice.isNotEmpty())
                item {
                    Banner(
                        "Note",
                        view.notice,
                        Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                    )
                }
            if (view.changes == null && (view.refreshing || view.busy))
                item {
                    Box(
                        Modifier.fillMaxWidth().padding(40.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Spinner(Modifier.size(24.dp))
                    }
                }
            if (files.isNotEmpty()) {
                item {
                    SectionHeader("${files.size} changed file${if (files.size == 1) "" else "s"}")
                }
                changedFiles(
                    files,
                    selected,
                    view.display_rows,
                    view,
                    onSelect = { path ->
                        val file = files.firstOrNull { it.path == path }
                        send(
                            ProjectChangesCommand(
                                select = ProjectChangeSelect(path, staged = file?.unstaged != true)
                            )
                        )
                    },
                    onComment = null,
                    onMore = { send(ProjectChangesCommand(load_more_diff = Step())) },
                    trailing = { file ->
                        if (file.unstaged && "stage" in view.allowed)
                            DButton(
                                "Stage",
                                {
                                    send(
                                        ProjectChangesCommand(
                                            run = GitOperationForm(kind = "stage", path = file.path)
                                        )
                                    )
                                },
                                kind = ButtonKind.PLAIN,
                            )
                        else if (file.staged && "unstage" in view.allowed)
                            DButton(
                                "Unstage",
                                {
                                    send(
                                        ProjectChangesCommand(
                                            run =
                                                GitOperationForm(kind = "unstage", path = file.path)
                                        )
                                    )
                                },
                                kind = ButtonKind.PLAIN,
                            )
                    },
                )
            }
            if (!view.refreshing && view.changes != null && files.isEmpty())
                item {
                    EmptyState(
                        Glyph.TASK_DONE,
                        "Working tree clean",
                        "This checkout has no uncommitted changes.",
                        Modifier.padding(top = 40.dp),
                    )
                }
        }
    }
    operation?.let { kind ->
        GitOperationEditor(kind, null, { operation = null }) {
            send(ProjectChangesCommand(run = it))
            operation = null
        }
    }
}

@Composable
internal fun ProcessesScreen(store: MobileStore) {
    val view by store.processes.collectAsState()
    val conversation by store.conversation.collectAsState()
    var confirm by remember { mutableStateOf(false) }
    fun send(value: ProcessesCommand) =
        store.command(Command(processes = value.copy(scope = MobileStore.PROCESSES_SCOPE)))
    DisposableEffect(store) {
        onDispose {
            send(
                ProcessesCommand(
                    bind = ProcessesTarget(view.daemon_id, view.project_id, view.card_id, false)
                )
            )
        }
    }
    Screen(
        ScreenChrome(
            "Processes",
            subtitle =
                listOf(conversation.card?.title.orEmpty(), "${view.running} running")
                    .filter { it.isNotEmpty() }
                    .joinToString(" · "),
        )
    ) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("processes"),
            state = listState,
            contentPadding = padding,
        ) {
            if (view.error.isNotEmpty())
                item {
                    Banner(
                        "Processes unavailable",
                        view.error,
                        Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                        tone = Tone.DANGER,
                    )
                }
            item { Spacer(Modifier.height(8.dp)) }
            if (view.loading && view.processes.isEmpty())
                item {
                    Box(
                        Modifier.fillMaxWidth().padding(40.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Spinner(Modifier.size(24.dp))
                    }
                }
            if (!view.loading && view.processes.isEmpty())
                item {
                    EmptyState(
                        Glyph.PROCESSES,
                        "No background processes",
                        "Dev servers, builds and tests the agent starts appear here.",
                        Modifier.padding(top = 40.dp),
                    )
                }
            view.processes.forEachIndexed { index, process ->
                val running = process.status == "running"
                item("process-${process.id}") {
                    ListRow(
                        process.name.ifEmpty { process.argv.firstOrNull().orEmpty() },
                        position = Position.of(index, view.processes.size),
                        subtitle = process.argv.joinToString(" "),
                        subtitleMaxLines = 1,
                        leading = {
                            if (running) LiveDot(palette.success, size = 10.dp)
                            else
                                Icon(
                                    Glyph.TERMINAL,
                                    null,
                                    tint = palette.secondaryLabel,
                                    size = 18.dp,
                                )
                        },
                        value = process.status,
                        selected = process.id == view.selected_id,
                        onClick = {
                            send(
                                ProcessesCommand(
                                    select =
                                        ProcessId(
                                            if (process.id == view.selected_id) "" else process.id
                                        )
                                )
                            )
                        },
                    )
                }
                if (process.id == view.selected_id)
                    item("output-${process.id}") {
                        Column(
                            Modifier.fillMaxWidth()
                                .padding(horizontal = ScreenMargin, vertical = 6.dp)
                        ) {
                            if (view.output_truncated)
                                Text(
                                    "Earlier output was truncated.",
                                    Modifier.padding(bottom = 4.dp),
                                    style = type.footnote,
                                    color = palette.secondaryLabel,
                                )
                            SelectionContainer {
                                Text(
                                    (view.stdout.utf8() + view.stderr.utf8()).ifEmpty {
                                        "No output yet."
                                    },
                                    Modifier.fillMaxWidth()
                                        .clip(RoundedCornerShape(14.dp))
                                        .background(androidx.compose.ui.graphics.Color(0xFF111113))
                                        .padding(12.dp),
                                    style = type.monoSmall,
                                    color = androidx.compose.ui.graphics.Color(0xFFE5E5EA),
                                )
                            }
                            if (view.can_stop)
                                DButton(
                                    "Stop process",
                                    { confirm = true },
                                    Modifier.padding(top = 8.dp),
                                    kind = ButtonKind.DESTRUCTIVE,
                                    glyph = Glyph.STOP,
                                    loading = view.stopping,
                                )
                        }
                    }
            }
        }
    }
    if (confirm)
        ConfirmDialog(
            "Stop this process?",
            "The conversation keeps running. Only this process stops.",
            "Stop",
            {
                send(ProcessesCommand(stop = Step()))
                confirm = false
            },
            { confirm = false },
            destructive = true,
        )
}
