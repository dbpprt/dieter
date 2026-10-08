@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.mobile

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.core.admin.Labels
import com.dbpprt.dieter.mobile.icons.*

@Composable
internal fun FolderEditor(
    store: MobileStore,
    scope: FolderScope,
    folder: NavigationFolder?,
    dismiss: () -> Unit,
) {
    var name by remember(folder?.id) { mutableStateOf(folder?.name.orEmpty()) }
    AlertDialog(
        onDismissRequest = dismiss,
        title = { Text(if (folder == null) "New folder" else "Edit folder") },
        text = {
            Column {
                MobileTextField(name, { name = it }, label = { Text("Folder name") })
                if (folder != null)
                    TextButton(
                        onClick = {
                            store.command(
                                Command(
                                    navigation =
                                        NavigationCommand(
                                            delete_folder = DeleteFolder(scope, folder.id)
                                        )
                                )
                            )
                            dismiss()
                        }
                    ) {
                        Text("Delete folder", color = colors.error)
                    }
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    store.command(
                        Command(
                            navigation =
                                if (folder == null)
                                    NavigationCommand(create_folder = CreateFolder(scope, name))
                                else
                                    NavigationCommand(
                                        rename_folder = RenameFolder(scope, folder.id, name)
                                    )
                        )
                    )
                    dismiss()
                },
                enabled = name.isNotBlank(),
            ) {
                Text("Save")
            }
        },
        dismissButton = { TextButton(onClick = dismiss) { Text("Cancel") } },
    )
}

@Composable
internal fun ProjectActions(store: MobileStore, id: String, dismiss: () -> Unit) {
    val workspace by store.workspace.collectAsState()
    val session by store.session.collectAsState()
    val navigation by store.navigation.collectAsState()
    val project = workspace.projects.firstOrNull { it.id == id } ?: return
    val conflictKeys =
        (project.conflict_keys +
                workspace.boards.filter { it.project_id == id }.flatMap { it.conflict_keys })
            .distinct()
    var mode by remember(id) { mutableStateOf("") }
    var name by remember(id, mode) { mutableStateOf(if (mode == "New board") "" else project.name) }
    var summary by remember(id) { mutableStateOf(project.summary) }
    var path by remember { mutableStateOf("") }
    var machine by remember { mutableStateOf("") }
    var remote by remember(id) { mutableStateOf(project.base_remote) }
    var branch by remember(id) { mutableStateOf(project.base_branch) }
    var workflow by remember { mutableStateOf("review") }
    var prompt by remember(id) { mutableStateOf(project.prompt_template) }
    var workspaces by remember(id) { mutableStateOf(ProjectWorkspacesSlice()) }
    var removal by remember { mutableStateOf<ProjectWorkspaceRemove?>(null) }
    var conflict by remember { mutableStateOf<com.dbpprt.dieter.api.v1.PeerRecord?>(null) }
    var conflictKey by remember { mutableStateOf("") }
    fun loadWorkspaces() = store.action {
        workspaces =
            store.core
                .dispatch(
                    Command(
                        project_workspaces =
                            ProjectWorkspacesCommand(load = ProjectWorkspacesLoad(id))
                    )
                )
                .project_workspaces ?: ProjectWorkspacesSlice()
    }
    LaunchedEffect(mode) { if (mode == "Workspaces") loadWorkspaces() }
    fun send(admin: AdminCommand) = store.command(Command(admin = admin))
    ModalBottomSheet(onDismissRequest = dismiss) {
        Column(
            Modifier.imePadding().verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(mode.ifEmpty { project.name }, style = MaterialTheme.typography.titleLarge)
            when (mode) {
                "Edit project" -> {
                    MobileTextField(
                        name,
                        { name = it },
                        label = { Text("Project name") },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    MobileTextField(
                        summary,
                        { summary = it },
                        label = { Text("Summary") },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    MobileTextField(
                        remote,
                        { remote = it },
                        label = { Text("Base remote") },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    MobileTextField(
                        branch,
                        { branch = it },
                        label = { Text("Base branch") },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    MobileTextField(
                        prompt,
                        { prompt = it },
                        label = { Text("Project prompt template") },
                        minLines = 3,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Button(
                        onClick = {
                            store.action {
                                store.core.dispatch(
                                    Command(
                                        admin =
                                            AdminCommand(
                                                update_project =
                                                    AdminUpdateProject(
                                                        project_id = id,
                                                        name = name,
                                                        summary = summary,
                                                    )
                                            )
                                    )
                                )
                                store.core.dispatch(
                                    Command(
                                        admin =
                                            AdminCommand(
                                                workspace_settings =
                                                    AdminWorkspaceSettings(
                                                        project_id = id,
                                                        base_remote = remote,
                                                        base_branch = branch,
                                                    )
                                            )
                                    )
                                )
                                store.core.dispatch(
                                    Command(
                                        admin =
                                            AdminCommand(
                                                set_project_prompt =
                                                    AdminScopedPrompt(
                                                        scope_id = id,
                                                        template = prompt,
                                                    )
                                            )
                                    )
                                )
                                dismiss()
                            }
                        },
                        enabled = name.isNotBlank(),
                    ) {
                        Text("Save")
                    }
                }
                "New board" -> {
                    MobileTextField(
                        name,
                        { name = it },
                        label = { Text("Board name") },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    ChoiceChip(workflow, listOf("review" to "With review", "direct" to "Direct")) {
                        workflow = it
                    }
                    Button(
                        onClick = {
                            store.action {
                                store.core
                                    .dispatch(
                                        Command(
                                            admin =
                                                AdminCommand(
                                                    create_board =
                                                        AdminCreateBoard(
                                                            project_id = id,
                                                            name = name,
                                                            workflow = workflow,
                                                        )
                                                )
                                        )
                                    )
                                    .board
                                    ?.let {
                                        store.chooseBoard(it.id)
                                        store.tab.value = MobileTab.BOARD
                                    }
                                dismiss()
                            }
                        },
                        enabled = name.isNotBlank(),
                    ) {
                        Text("Create board")
                    }
                }
                "Checkouts" -> {
                    project.checkouts.forEach { checkout ->
                        FormSection(checkout.name) {
                            Text(checkout.path, style = MaterialTheme.typography.bodySmall)
                            Text(
                                session.machines
                                    .firstOrNull { it.id == checkout.daemon_id }
                                    ?.display_name ?: checkout.daemon_id
                            )
                            TextButton(
                                onClick = {
                                    send(
                                        AdminCommand(
                                            detach_checkout = AdminCheckout(id, checkout.id)
                                        )
                                    )
                                }
                            ) {
                                Text("Detach checkout")
                            }
                        }
                    }
                    ChoiceChip(
                        session.machines.firstOrNull { it.id == machine }?.display_name
                            ?: "Choose machine",
                        session.machines.filter { it.available }.map { it.id to it.display_name },
                    ) {
                        machine = it
                    }
                    MobileTextField(
                        path,
                        { path = it },
                        label = { Text("Existing repository path") },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Button(
                        onClick = {
                            send(
                                AdminCommand(
                                    attach_checkout =
                                        AdminAttachCheckout(
                                            daemon_id = machine,
                                            project_id = id,
                                            path = path,
                                        )
                                )
                            )
                            path = ""
                        },
                        enabled = machine.isNotEmpty() && path.isNotBlank(),
                    ) {
                        Text("Attach checkout")
                    }
                }
                "Workspaces" -> {
                    TextButton(onClick = { loadWorkspaces() }) { Text("Refresh workspaces") }
                    if (workspaces.error.isNotEmpty()) Text(workspaces.error, color = colors.error)
                    workspaces.rows.forEach { row ->
                        FormSection(row.title) {
                            Text(row.detail)
                            Text(row.stats, style = MaterialTheme.typography.bodySmall)
                            Text(row.path, style = MaterialTheme.typography.bodySmall)
                            if (row.error.isNotEmpty()) Text(row.error, color = colors.error)
                            if (row.pending) LinearProgressIndicator(Modifier.fillMaxWidth())
                            Row {
                                TextButton(
                                    onClick = {
                                        store.openCard(row.card_id)
                                        dismiss()
                                    }
                                ) {
                                    Text("Open conversation")
                                }
                                if (row.can_clean_up)
                                    TextButton(
                                        onClick = {
                                            removal = ProjectWorkspaceRemove(row.card_id, false)
                                        },
                                        enabled = !row.pending,
                                    ) {
                                        Text("Clean up")
                                    }
                                if (row.can_discard)
                                    TextButton(
                                        onClick = {
                                            removal = ProjectWorkspaceRemove(row.card_id, true)
                                        },
                                        enabled = !row.pending,
                                    ) {
                                        Text("Discard…")
                                    }
                            }
                        }
                    }
                    if (workspaces.rows.isEmpty() && workspaces.error.isEmpty())
                        Text("No conversation workspaces")
                }
                "Conflicts" -> {
                    conflictKeys.forEach { key ->
                        TextButton(
                            onClick = {
                                store.action {
                                    conflictKey = key
                                    conflict =
                                        store.core
                                            .dispatch(
                                                Command(
                                                    admin =
                                                        AdminCommand(
                                                            conflict = AdminConflict(id, key)
                                                        )
                                                )
                                            )
                                            .conflict
                                            ?.record
                                }
                            }
                        ) {
                            Text(key)
                        }
                    }
                    if (conflictKeys.isEmpty()) Text("No replicated setting conflicts")
                }
                "Archive project" -> {
                    Text(
                        "Archive this project and its boards? The conversations remain recoverable."
                    )
                    Button(
                        onClick = {
                            send(
                                AdminCommand(set_project_archived = AdminProjectArchived(id, true))
                            )
                            dismiss()
                        }
                    ) {
                        Text("Archive")
                    }
                }
                else -> {
                    TextButton(
                        onClick = {
                            store.command(
                                Command(
                                    navigation =
                                        NavigationCommand(
                                            pin_project =
                                                PinProject(id, id !in navigation.pinned_projects)
                                        )
                                )
                            )
                            dismiss()
                        }
                    ) {
                        Text(
                            if (id in navigation.pinned_projects) "Unpin project" else "Pin project"
                        )
                    }
                    ChoiceChip(
                        "Move to folder",
                        listOf("" to "No folder") +
                            navigation.project_folders.map { it.id to it.name },
                    ) {
                        store.command(
                            Command(
                                navigation =
                                    NavigationCommand(
                                        move_to_folder =
                                            MoveToFolder(FolderScope.FOLDER_SCOPE_PROJECTS, id, it)
                                    )
                            )
                        )
                        dismiss()
                    }
                    listOf(
                            "Edit project",
                            "New board",
                            "Checkouts",
                            "Workspaces",
                            "Conflicts",
                            "Archive project",
                        )
                        .forEach { label -> TextButton(onClick = { mode = label }) { Text(label) } }
                }
            }
        }
    }
    removal?.let { request ->
        AlertDialog(
            onDismissRequest = { removal = null },
            title = { Text(if (request.discard) "Discard workspace?" else "Clean up workspace?") },
            text = {
                Text(
                    if (request.discard)
                        "This removes the worktree and its uncommitted changes. The conversation is retained."
                    else "This removes this clean, inactive worktree. The conversation is retained."
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        store.action {
                            workspaces =
                                store.core
                                    .dispatch(
                                        Command(
                                            project_workspaces =
                                                ProjectWorkspacesCommand(remove = request)
                                        )
                                    )
                                    .project_workspaces ?: workspaces
                            removal = null
                        }
                    }
                ) {
                    Text(
                        if (request.discard) "Discard workspace" else "Clean up",
                        color = if (request.discard) colors.error else colors.primary,
                    )
                }
            },
            dismissButton = { TextButton(onClick = { removal = null }) { Text("Cancel") } },
        )
    }
    conflict?.let { record ->
        AlertDialog(
            onDismissRequest = { conflict = null },
            title = { Text("Resolve $conflictKey") },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    Text("Choose the version to keep.")
                    record.versions.forEachIndexed { index, version ->
                        FormSection("Version ${index + 1}") {
                            Text(
                                if (version.deleted) "Deleted" else version.value_json.utf8(),
                                style = MaterialTheme.typography.bodySmall,
                            )
                            TextButton(
                                onClick = {
                                    store.action {
                                        store.core.dispatch(
                                            Command(
                                                admin =
                                                    AdminCommand(
                                                        resolve_conflict =
                                                            AdminResolveConflict(
                                                                id,
                                                                record,
                                                                version.value_json,
                                                                version.deleted,
                                                            )
                                                    )
                                            )
                                        )
                                        conflict = null
                                    }
                                }
                            ) {
                                Text("Keep this version")
                            }
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { conflict = null }) { Text("Cancel") } },
        )
    }
}

@Composable
internal fun BoardSettings(store: MobileStore, dismiss: () -> Unit) {
    val workspace by store.workspace.collectAsState()
    val board = workspace.boards.firstOrNull { it.id == store.selectedBoard.value } ?: return
    var name by remember(board.id) { mutableStateOf(board.name) }
    var remote by remember(board.id) { mutableStateOf(board.base_remote) }
    var publish by remember(board.id) { mutableStateOf(board.remote_publish_mode) }
    var archive by remember(board.id) { mutableStateOf(board.done_archive_policy) }
    var prompt by remember(board.id) { mutableStateOf(board.prompt_template) }
    var editingLabel by remember { mutableStateOf<AdminLabel?>(null) }
    var labelName by remember { mutableStateOf("") }
    var labelColor by remember { mutableStateOf(Labels.PALETTE.first()) }
    var labelInstructions by remember { mutableStateOf("") }
    fun send(value: AdminCommand) = store.command(Command(admin = value))
    ModalBottomSheet(onDismissRequest = dismiss) {
        Column(
            Modifier.imePadding().verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Board settings", style = MaterialTheme.typography.titleLarge)
            MobileTextField(
                name,
                { name = it },
                label = { Text("Board name") },
                modifier = Modifier.fillMaxWidth(),
            )
            MobileTextField(
                remote,
                { remote = it },
                label = { Text("Base remote") },
                modifier = Modifier.fillMaxWidth(),
            )
            ChoiceChip(
                publish.ifEmpty { "Manual" },
                listOf(
                    "manual" to "Manual",
                    "push_base" to "Push base",
                    "pull_request" to "Pull request",
                ),
            ) {
                publish = it
            }
            ChoiceChip(
                archive.ifEmpty { "Keep done cards" },
                listOf(
                    "never" to "Keep done cards",
                    "immediately" to "Immediately",
                    "after_1_day" to "After 1 day",
                    "after_7_days" to "After 7 days",
                    "after_30_days" to "After 30 days",
                    "after_90_days" to "After 90 days",
                ),
            ) {
                archive = it
            }
            MobileTextField(
                prompt,
                { prompt = it },
                label = { Text("Board prompt template") },
                minLines = 3,
                modifier = Modifier.fillMaxWidth(),
            )
            Button(
                onClick = {
                    store.action {
                        store.core.dispatch(
                            Command(
                                admin =
                                    AdminCommand(rename_board = AdminRenameBoard(board.id, name))
                            )
                        )
                        store.core.dispatch(
                            Command(
                                admin =
                                    AdminCommand(
                                        set_git_settings =
                                            AdminGitSettings(board.id, remote, publish)
                                    )
                            )
                        )
                        store.core.dispatch(
                            Command(
                                admin =
                                    AdminCommand(
                                        set_archive_policy = AdminArchivePolicy(board.id, archive)
                                    )
                            )
                        )
                        store.core.dispatch(
                            Command(
                                admin =
                                    AdminCommand(
                                        set_board_prompt = AdminScopedPrompt(board.id, prompt)
                                    )
                            )
                        )
                        dismiss()
                    }
                },
                enabled = name.isNotBlank(),
            ) {
                Text("Save board")
            }
            Text("Labels", style = MaterialTheme.typography.titleMedium)
            board.labels.forEach { label ->
                Row {
                    TextButton(
                        onClick = {
                            editingLabel = AdminLabel(board.id, label.id)
                            labelName = label.name
                            labelColor = label.color
                            labelInstructions = label.instructions
                        }
                    ) {
                        LabelPill(label.name, label.color)
                    }
                    IconButton(
                        onClick = {
                            send(AdminCommand(delete_label = AdminLabel(board.id, label.id)))
                        }
                    ) {
                        Icon(Icons.Outlined.Delete, "Delete label")
                    }
                }
            }
            OutlinedButton(
                onClick = {
                    editingLabel = AdminLabel(board.id)
                    labelName = ""
                    labelInstructions = ""
                }
            ) {
                Text("New label")
            }
        }
    }
    editingLabel?.let { value ->
        AlertDialog(
            onDismissRequest = { editingLabel = null },
            title = { Text(if (value.label_id.isEmpty()) "New label" else "Edit label") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    MobileTextField(labelName, { labelName = it }, label = { Text("Label name") })
                    ChoiceChip(
                        Labels.named(labelColor).name,
                        Labels.COLORS.map { it.value to it.name },
                    ) {
                        labelColor = it
                    }
                    MobileTextField(labelColor, { labelColor = it }, label = { Text("Hex color") })
                    MobileTextField(
                        labelInstructions,
                        { labelInstructions = it },
                        label = { Text("Agent instructions") },
                        minLines = 2,
                    )
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        val label =
                            value.copy(
                                name = labelName,
                                color = labelColor,
                                instructions = labelInstructions,
                            )
                        send(
                            if (value.label_id.isEmpty()) AdminCommand(create_label = label)
                            else AdminCommand(update_label = label)
                        )
                        editingLabel = null
                    },
                    enabled = Labels.validate(labelName, labelColor) == null,
                ) {
                    Text("Save")
                }
            },
            dismissButton = { TextButton(onClick = { editingLabel = null }) { Text("Cancel") } },
        )
    }
}

@Composable
internal fun ArchivedCards(store: MobileStore, boardId: String, dismiss: () -> Unit) {
    var cards by remember { mutableStateOf<List<Card>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    LaunchedEffect(boardId) {
        store.action {
            cards =
                store.core
                    .dispatch(Command(list_archived_cards = ListArchivedCards(boardId)))
                    .cards
                    ?.cards
                    .orEmpty()
            loading = false
        }
    }
    ModalBottomSheet(onDismissRequest = dismiss) {
        Column(Modifier.fillMaxWidth().padding(16.dp)) {
            Text("Archived cards", style = MaterialTheme.typography.titleLarge)
            if (loading) LinearProgressIndicator(Modifier.fillMaxWidth())
            LazyColumn {
                items(cards, key = { it.id }) { card ->
                    ListItem(
                        headlineContent = { Text(card.title) },
                        supportingContent = { Text(card.summary) },
                        trailingContent = {
                            TextButton(
                                onClick = {
                                    store.action {
                                        store.core.dispatch(
                                            Command(restore_card = RestoreCard(card_id = card.id))
                                        )
                                        cards = cards.filter { it.id != card.id }
                                    }
                                }
                            ) {
                                Text("Restore")
                            }
                        },
                    )
                }
            }
        }
    }
}
