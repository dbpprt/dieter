@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.getdieter.mobile.admin

import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.*
import com.getdieter.core.admin.PromptTemplates
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.design.Tone
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.store.*

@Composable
internal fun FolderEditor(
    store: MobileStore,
    scope: FolderScope,
    folder: NavigationFolder?,
    dismiss: () -> Unit,
) {
    var deleting by remember { mutableStateOf(false) }
    if (folder == null) {
        PromptDialog(
            "New folder",
            "",
            "Create",
            { name ->
                store.command(
                    Command(
                        navigation = NavigationCommand(create_folder = CreateFolder(scope, name))
                    )
                )
                dismiss()
            },
            dismiss,
            placeholder = "Folder name",
        )
        return
    }
    Sheet(folder.name, dismiss, size = SheetSize.MEDIUM) {
        var name by remember(folder.id) { mutableStateOf(folder.name) }
        FormColumn {
            MobileTextField(
                name,
                { name = it },
                Modifier.fillMaxWidth(),
                label = { Text("Name") },
                placeholder = { Text("Folder name") },
                singleLine = true,
            )
            DButton(
                "Save",
                {
                    store.command(
                        Command(
                            navigation =
                                NavigationCommand(
                                    rename_folder = RenameFolder(scope, folder.id, name)
                                )
                        )
                    )
                    dismiss()
                },
                Modifier.fillMaxWidth(),
                enabled = name.isNotBlank(),
                large = true,
            )
            DButton(
                "Delete folder",
                { deleting = true },
                Modifier.fillMaxWidth(),
                kind = ButtonKind.DESTRUCTIVE,
                large = true,
            )
        }
    }
    if (deleting)
        ConfirmDialog(
            "Delete “${folder.name}”?",
            "Its items move out of the folder.",
            "Delete",
            {
                store.command(
                    Command(
                        navigation =
                            NavigationCommand(delete_folder = DeleteFolder(scope, folder.id))
                    )
                )
                deleting = false
                dismiss()
            },
            { deleting = false },
            destructive = true,
        )
}

/** Project administration presented from the project menu. */
@Composable
internal fun ProjectActionSheet(store: MobileStore, id: String, mode: String, dismiss: () -> Unit) {
    val workspace by store.workspace.slice.collectAsState()
    val project = workspace.projects.firstOrNull { it.id == id } ?: return
    when (mode) {
        "Edit project" -> ProjectSettingsSheet(store, project, dismiss)
        "New board" -> NewBoardSheet(store, id, dismiss)
        "Checkouts" -> CheckoutsSheet(store, project, dismiss)
        "Workspaces" -> WorkspacesSheet(store, id, dismiss)
        "Conflicts" -> ConflictsSheet(store, project, dismiss)
        "Archive project" ->
            ConfirmDialog(
                "Archive “${project.name}”?",
                "Its boards are archived too. Conversations remain recoverable.",
                "Archive",
                {
                    store.command(
                        Command(
                            admin =
                                AdminCommand(set_project_archived = AdminProjectArchived(id, true))
                        )
                    )
                    dismiss()
                    if (
                        store.routes.value.stack.any {
                            it is MobileRoute.Project && it.projectId == id
                        }
                    )
                        store.selectTab(MobileTab.PROJECTS)
                },
                dismiss,
                destructive = true,
            )
    }
}

@Composable
private fun ProjectSettingsSheet(
    store: MobileStore,
    project: com.getdieter.api.v1.Project,
    dismiss: () -> Unit,
) {
    var name by remember(project.id) { mutableStateOf(project.name) }
    var summary by remember(project.id) { mutableStateOf(project.summary) }
    var remote by remember(project.id) { mutableStateOf(project.base_remote) }
    var branch by remember(project.id) { mutableStateOf(project.base_branch) }
    var instructions by remember(project.id) { mutableStateOf(project.prompt) }
    var template by remember(project.id) { mutableStateOf(project.prompt_template) }
    val templateProblem =
        template.takeIf { it.isNotBlank() }?.let { PromptTemplates.validate(it, context = true) }
    val gitChanged = remote != project.base_remote || branch != project.base_branch
    Sheet(
        "Edit Project",
        dismiss,
        confirm =
            ChromeAction(
                "save-project",
                "Save",
                Glyph.CHECK,
                enabled =
                    name.isNotBlank() &&
                        templateProblem == null &&
                        (!gitChanged || branch.isNotBlank()),
            ) {
                store.action {
                    store.core.dispatch(
                        Command(
                            admin =
                                AdminCommand(
                                    update_project =
                                        AdminUpdateProject(
                                            project_id = project.id,
                                            name = name,
                                            summary = summary,
                                            prompt = instructions,
                                        )
                                )
                        )
                    )
                    if (gitChanged)
                        store.core.dispatch(
                            Command(
                                admin =
                                    AdminCommand(
                                        workspace_settings =
                                            AdminWorkspaceSettings(
                                                project_id = project.id,
                                                base_remote = remote,
                                                base_branch = branch,
                                            )
                                    )
                            )
                        )
                    if (template != project.prompt_template)
                        store.core.dispatch(
                            Command(
                                admin =
                                    AdminCommand(
                                        set_project_prompt =
                                            AdminScopedPrompt(
                                                scope_id = project.id,
                                                template = template.takeIf { it.isNotBlank() },
                                            )
                                    )
                            )
                        )
                    dismiss()
                }
            },
    ) {
        FormColumn {
            MobileTextField(
                name,
                { name = it },
                Modifier.fillMaxWidth(),
                label = { Text("Name") },
                placeholder = { Text("Project name") },
                singleLine = true,
            )
            MobileTextField(
                summary,
                { summary = it },
                Modifier.fillMaxWidth(),
                label = { Text("Summary") },
                placeholder = { Text("Summary") },
            )
        }
        SectionHeader("Git")
        FormColumn {
            MobileTextField(
                remote,
                { remote = it },
                Modifier.fillMaxWidth(),
                label = { Text("Base remote") },
                placeholder = { Text("origin") },
                singleLine = true,
            )
            MobileTextField(
                branch,
                { branch = it },
                Modifier.fillMaxWidth(),
                label = { Text("Base branch") },
                placeholder = { Text("main") },
                singleLine = true,
            )
        }
        SectionHeader("Agent instructions")
        FormColumn {
            MobileTextField(
                instructions,
                { instructions = it },
                Modifier.fillMaxWidth(),
                label = { Text("Project instructions") },
                placeholder = { Text("Instructions added to every task in this project") },
                minLines = 4,
            )
        }
        SectionFooter(
            "Shared by every board in this project and by all your devices.",
            Modifier.padding(horizontal = 20.dp),
        )
        SectionHeader("Prompt template override")
        FormColumn {
            MobileTextField(
                template,
                { template = it },
                Modifier.fillMaxWidth(),
                label = { Text("Template") },
                placeholder = { Text("Empty inherits the global template") },
                minLines = 3,
            )
        }
        SectionFooter(
            templateProblem
                ?: "Replaces the whole agent prompt for this project. It must place " +
                    "{{project.instructions_block}} and {{labels.instructions_block}} once.",
            Modifier.padding(horizontal = 20.dp),
        )
    }
}

@Composable
private fun NewBoardSheet(store: MobileStore, projectId: String, dismiss: () -> Unit) {
    var name by remember { mutableStateOf("") }
    var review by remember { mutableStateOf(true) }
    Sheet(
        "New Board",
        dismiss,
        size = SheetSize.MEDIUM,
        confirm =
            ChromeAction("create-board", "Create", Glyph.CHECK, enabled = name.isNotBlank()) {
                store.action {
                    store.core
                        .dispatch(
                            Command(
                                admin =
                                    AdminCommand(
                                        create_board =
                                            AdminCreateBoard(
                                                project_id = projectId,
                                                name = name,
                                                workflow = if (review) "review" else "direct",
                                            )
                                    )
                            )
                        )
                        .board
                        ?.let { board ->
                            dismiss()
                            store.push(MobileRoute.Board(board.id))
                        } ?: dismiss()
                }
            },
    ) {
        FormColumn {
            MobileTextField(
                name,
                { name = it },
                Modifier.fillMaxWidth(),
                label = { Text("Name") },
                placeholder = { Text("Board name") },
                singleLine = true,
            )
        }
        Group(listOf(0)) { _, position ->
            ListRow(
                "Review lane",
                position = position,
                subtitle = "Cards move to Review before Done",
                trailing = { DSwitch(review, { review = it }) },
            )
        }
    }
}

@Composable
private fun CheckoutsSheet(
    store: MobileStore,
    project: com.getdieter.api.v1.Project,
    dismiss: () -> Unit,
) {
    val session by store.session.slice.collectAsState()
    var path by remember { mutableStateOf("") }
    var machine by remember { mutableStateOf("") }
    var detaching by remember { mutableStateOf<com.getdieter.api.v1.Checkout?>(null) }
    val machines = session.machines.filter { it.available }
    Sheet("Checkouts", dismiss) {
        SectionHeader("Attached")
        if (project.checkouts.isEmpty()) SectionFooter("No checkouts are attached to this project.")
        Group(project.checkouts) { checkout, position ->
            ListRow(
                session.machines.firstOrNull { it.id == checkout.daemon_id }?.display_name
                    ?: checkout.daemon_id,
                position = position,
                subtitle = checkout.path,
                glyph = Glyph.MACHINE,
                trailing = { DButton("Detach", { detaching = checkout }, kind = ButtonKind.PLAIN) },
            )
        }
        SectionHeader("Attach an existing repository")
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
        FormColumn {
            MobileTextField(
                path,
                { path = it },
                Modifier.fillMaxWidth(),
                label = { Text("Path") },
                placeholder = { Text("Repository path on the machine") },
                singleLine = true,
            )
            DButton(
                "Attach checkout",
                {
                    store.command(
                        Command(
                            admin =
                                AdminCommand(
                                    attach_checkout =
                                        AdminAttachCheckout(
                                            daemon_id = machine,
                                            project_id = project.id,
                                            path = path,
                                        )
                                )
                        )
                    )
                    path = ""
                },
                Modifier.fillMaxWidth(),
                enabled = machine.isNotEmpty() && path.isNotBlank(),
                large = true,
            )
        }
    }
    detaching?.let { checkout ->
        ConfirmDialog(
            "Detach checkout?",
            checkout.path,
            "Detach",
            {
                store.command(
                    Command(
                        admin =
                            AdminCommand(detach_checkout = AdminCheckout(project.id, checkout.id))
                    )
                )
                detaching = null
            },
            { detaching = null },
            destructive = true,
        )
    }
}

@Composable
private fun WorkspacesSheet(store: MobileStore, projectId: String, dismiss: () -> Unit) {
    var workspaces by remember(projectId) { mutableStateOf(ProjectWorkspacesSlice()) }
    var removal by remember { mutableStateOf<ProjectWorkspaceRemove?>(null) }
    fun load() = store.action {
        workspaces =
            store.core
                .dispatch(
                    Command(
                        project_workspaces =
                            ProjectWorkspacesCommand(load = ProjectWorkspacesLoad(projectId))
                    )
                )
                .project_workspaces ?: ProjectWorkspacesSlice()
    }
    LaunchedEffect(projectId) { load() }
    Sheet("Workspaces", dismiss) {
        if (workspaces.error.isNotEmpty())
            Banner(
                "Workspaces unavailable",
                workspaces.error,
                Modifier.padding(horizontal = ScreenMargin, vertical = 8.dp),
                tone = Tone.WARNING,
                actionLabel = "Retry",
                onAction = { load() },
            )
        if (workspaces.rows.isEmpty() && workspaces.error.isEmpty())
            SectionFooter("No conversation worktrees for this project.")
        workspaces.rows.forEach { row ->
            ContentCard(Modifier.padding(horizontal = ScreenMargin, vertical = 5.dp)) {
                Text(row.title, style = type.headline, color = palette.label)
                Text(
                    listOf(row.detail, row.stats).filter { it.isNotEmpty() }.joinToString(" · "),
                    style = type.footnote,
                    color = palette.secondaryLabel,
                )
                Text(row.path, style = type.monoSmall, color = palette.secondaryLabel)
                if (row.error.isNotEmpty())
                    Text(row.error, style = type.footnote, color = palette.destructive)
                Row(
                    Modifier.padding(top = 6.dp),
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    DButton(
                        "Open",
                        {
                            dismiss()
                            store.openConversation(row.card_id)
                        },
                        kind = ButtonKind.TONAL,
                    )
                    if (row.can_clean_up)
                        DButton(
                            "Clean up",
                            { removal = ProjectWorkspaceRemove(row.card_id, false) },
                            kind = ButtonKind.PLAIN,
                            enabled = !row.pending,
                        )
                    if (row.can_discard)
                        DButton(
                            "Discard…",
                            { removal = ProjectWorkspaceRemove(row.card_id, true) },
                            kind = ButtonKind.PLAIN,
                            enabled = !row.pending,
                        )
                    if (row.pending) Spinner(Modifier.size(16.dp))
                }
            }
        }
    }
    removal?.let { request ->
        ConfirmDialog(
            if (request.discard) "Discard workspace?" else "Clean up workspace?",
            if (request.discard)
                "This removes the worktree and its uncommitted changes. The conversation is kept."
            else "This removes this clean, inactive worktree. The conversation is kept.",
            if (request.discard) "Discard" else "Clean up",
            {
                store.action {
                    workspaces =
                        store.core
                            .dispatch(
                                Command(
                                    project_workspaces = ProjectWorkspacesCommand(remove = request)
                                )
                            )
                            .project_workspaces ?: workspaces
                    removal = null
                }
            },
            { removal = null },
            destructive = request.discard,
        )
    }
}

@Composable
private fun ConflictsSheet(
    store: MobileStore,
    project: com.getdieter.api.v1.Project,
    dismiss: () -> Unit,
) {
    val workspace by store.workspace.slice.collectAsState()
    var conflict by remember { mutableStateOf<com.getdieter.api.v1.PeerRecord?>(null) }
    var conflictKey by remember { mutableStateOf("") }
    val keys =
        (project.conflict_keys +
                workspace.boards
                    .filter { it.project_id == project.id }
                    .flatMap { it.conflict_keys })
            .distinct()
    Sheet("Setting Conflicts", dismiss) {
        if (keys.isEmpty())
            EmptyState(
                Glyph.TASK_DONE,
                "No conflicts",
                "Replicated settings agree on every machine.",
            )
        val record = conflict
        if (record == null)
            Group(keys) { key, position ->
                ListRow(
                    key,
                    position = position,
                    accessory = Accessory.CHEVRON,
                    onClick = {
                        store.action {
                            conflictKey = key
                            conflict =
                                store.core
                                    .dispatch(
                                        Command(
                                            admin =
                                                AdminCommand(
                                                    conflict = AdminConflict(project.id, key)
                                                )
                                        )
                                    )
                                    .conflict
                                    ?.record
                        }
                    },
                )
            }
        else {
            SectionHeader(conflictKey)
            record.versions.forEachIndexed { index, version ->
                ContentCard(Modifier.padding(horizontal = ScreenMargin, vertical = 5.dp)) {
                    Text("Version ${index + 1}", style = type.headline, color = palette.label)
                    Text(
                        if (version.deleted) "Deleted" else version.value_json.utf8(),
                        style = type.monoSmall,
                        color = palette.secondaryLabel,
                    )
                    DButton(
                        "Keep this version",
                        {
                            store.action {
                                store.core.dispatch(
                                    Command(
                                        admin =
                                            AdminCommand(
                                                resolve_conflict =
                                                    AdminResolveConflict(
                                                        project.id,
                                                        record,
                                                        version.value_json,
                                                        version.deleted,
                                                    )
                                            )
                                    )
                                )
                                conflict = null
                            }
                        },
                        Modifier.padding(top = 8.dp),
                        kind = ButtonKind.TONAL,
                    )
                }
            }
        }
    }
}
