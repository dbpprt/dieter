package com.dbpprt.dieter.mobile

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.core.workspace.GitOperations

@Composable
internal fun ProjectChangesScreen(store: MobileStore) {
    val view by store.projectChanges.collectAsState()
    var operation by remember { mutableStateOf<String?>(null) }
    fun send(value: ProjectChangesCommand) =
        store.command(
            Command(project_changes = value.copy(scope = MobileStore.PROJECT_CHANGES_SCOPE))
        )
    DisposableEffect(store) {
        send(ProjectChangesCommand(active = Toggle(true)))
        onDispose { send(ProjectChangesCommand(active = Toggle(false))) }
    }
    Column {
        PageHeader(
            "Project changes",
            view.changes?.branch.orEmpty(),
            back = { store.navigate(MobileTab.PROJECTS) },
        )
        ProjectSelector(store)
        Row(
            Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            AssistChip(
                onClick = { send(ProjectChangesCommand(refresh = Step())) },
                label = { Text("Refresh") },
            )
            view.allowed.forEach { kind ->
                AssistChip(
                    onClick = { operation = kind },
                    label = { Text(GitOperations.title(kind)) },
                    enabled = !view.mutations_disabled,
                )
            }
            FilterChip(
                view.split,
                { send(ProjectChangesCommand(layout = ReviewLayout(!view.split))) },
                label = { Text("Split diff") },
            )
        }
        listOf(view.refresh_error, view.diff_error, view.operation_error)
            .filter { it.isNotEmpty() }
            .forEach {
                Notice(
                    "Changes unavailable",
                    it,
                    { send(ProjectChangesCommand(refresh = Step())) },
                    danger = true,
                )
            }
        if (view.busy || view.diff_loading) LinearProgressIndicator(Modifier.fillMaxWidth())
        LazyColumn(
            contentPadding = PaddingValues(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (view.notice.isNotEmpty()) item { Text(view.notice) }
            items(view.changes?.files.orEmpty(), key = { it.path }) { file ->
                FormSection(file.path) {
                    Text(
                        "+${file.additions} −${file.deletions}",
                        style = MaterialTheme.typography.labelSmall,
                    )
                    Row {
                        if (file.unstaged)
                            TextButton(
                                onClick = {
                                    send(
                                        ProjectChangesCommand(
                                            select = ProjectChangeSelect(file.path, false)
                                        )
                                    )
                                }
                            ) {
                                Text("Unstaged diff")
                            }
                        if (file.staged)
                            TextButton(
                                onClick = {
                                    send(
                                        ProjectChangesCommand(
                                            select = ProjectChangeSelect(file.path, true)
                                        )
                                    )
                                }
                            ) {
                                Text("Staged diff")
                            }
                        if (file.unstaged && "stage" in view.allowed)
                            TextButton(
                                onClick = {
                                    send(
                                        ProjectChangesCommand(
                                            run = GitOperationForm(kind = "stage", path = file.path)
                                        )
                                    )
                                }
                            ) {
                                Text("Stage")
                            }
                        if (file.staged && "unstage" in view.allowed)
                            TextButton(
                                onClick = {
                                    send(
                                        ProjectChangesCommand(
                                            run =
                                                GitOperationForm(kind = "unstage", path = file.path)
                                        )
                                    )
                                }
                            ) {
                                Text("Unstage")
                            }
                    }
                }
            }
            itemsIndexed(view.display_rows) { _, row -> DiffRowView(row) }
            if (view.diff_more)
                item {
                    TextButton(onClick = { send(ProjectChangesCommand(load_more_diff = Step())) }) {
                        Text("Load the rest of this diff")
                    }
                }
            if (view.diff_note.isNotEmpty()) item { Text(view.diff_note) }
            if (!view.refreshing && view.changes != null && view.changes!!.files.isEmpty())
                item {
                    Box(Modifier.height(180.dp)) {
                        Empty("Working tree clean", "No uncommitted changes in this checkout.")
                    }
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
    fun send(value: ProcessesCommand) =
        store.command(Command(processes = value.copy(scope = MobileStore.PROCESSES_SCOPE)))
    var confirm by remember { mutableStateOf(false) }
    DisposableEffect(store) {
        onDispose {
            send(
                ProcessesCommand(
                    bind = ProcessesTarget(view.daemon_id, view.project_id, view.card_id, false)
                )
            )
        }
    }
    Column {
        PageHeader("Processes", "${view.running} running")
        if (view.error.isNotEmpty())
            Text(view.error, color = colors.error, modifier = Modifier.padding(12.dp))
        LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(12.dp)) {
            items(view.processes, key = { it.id }) { process ->
                ListItem(
                    headlineContent = {
                        Text(process.name.ifEmpty { process.argv.firstOrNull().orEmpty() })
                    },
                    supportingContent = {
                        Text(process.status + " · " + process.argv.joinToString(" "))
                    },
                    modifier =
                        Modifier.clickable {
                            send(ProcessesCommand(select = ProcessId(process.id)))
                        },
                )
            }
            if (view.selected_id.isNotEmpty())
                item {
                    FormSection("Output") {
                        if (view.output_truncated)
                            Text(
                                "Earlier output was truncated",
                                style = MaterialTheme.typography.labelSmall,
                            )
                        SelectionContainer {
                            Text(
                                view.stdout.utf8() + view.stderr.utf8(),
                                style = MaterialTheme.typography.bodySmall,
                                fontFamily = FontFamily.Monospace,
                            )
                        }
                        if (view.can_stop)
                            OutlinedButton(onClick = { confirm = true }) { Text("Stop process") }
                    }
                }
            if (!view.loading && view.processes.isEmpty())
                item {
                    Box(Modifier.height(200.dp)) {
                        Empty(
                            "No background processes",
                            "Processes started for this conversation appear here.",
                        )
                    }
                }
        }
    }
    if (confirm)
        AlertDialog(
            onDismissRequest = { confirm = false },
            title = { Text("Stop this process?") },
            text = {
                Text("The conversation remains active. Only this selected process is stopped.")
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        send(ProcessesCommand(stop = Step()))
                        confirm = false
                    }
                ) {
                    Text("Stop")
                }
            },
            dismissButton = { TextButton(onClick = { confirm = false }) { Text("Cancel") } },
        )
}
