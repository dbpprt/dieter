@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.mobile

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.core.files.FilePaths
import com.dbpprt.dieter.mobile.icons.*
import com.dbpprt.dieter.settings.DieterPalette

@Composable
internal fun ProjectSelector(store: MobileStore) {
    val workspace by store.workspace.collectAsState()
    val selected by store.selectedProject.collectAsState()
    val checkout by store.selectedCheckout.collectAsState()
    val defaults by store.creationDefaults.collectAsState()
    val project =
        workspace.projects.firstOrNull { it.id == selected.ifEmpty { store.currentProjectId() } }
    Row(Modifier.padding(horizontal = 16.dp)) {
        ChoiceChip(
            workspace.projects
                .firstOrNull { it.id == selected.ifEmpty { store.currentProjectId() } }
                ?.name ?: "Choose project",
            workspace.projects.map { it.id to it.name },
        ) { id ->
            store.selectedProject.value = id
            store.selectedCheckout.value = ""
            store.navigate(store.tab.value)
        }
    }
    if (store.tab.value in listOf(MobileTab.FILES, MobileTab.PROJECT_CHANGES))
        Row(Modifier.padding(horizontal = 16.dp)) {
            ChoiceChip(
                project
                    ?.checkouts
                    ?.firstOrNull {
                        it.id == checkout.ifEmpty { defaults.checkouts[project?.id].orEmpty() }
                    }
                    ?.name ?: "Choose a checkout",
                project?.checkouts.orEmpty().map { it.id to it.name },
            ) {
                store.selectedCheckout.value = it
                if (store.tab.value == MobileTab.PROJECT_CHANGES) store.bindProjectChanges()
                else store.bindFiles()
            }
        }
}

@Composable
internal fun FilesScreen(store: MobileStore, inConversation: Boolean = false) {
    val view by store.files.collectAsState()
    val previewAttachment = rememberAttachmentViewer { store.error.value = it }
    var create by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }
    var directory by remember { mutableStateOf(false) }
    var entryActions by remember { mutableStateOf<com.dbpprt.dieter.api.v1.FileEntry?>(null) }
    var moving by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    var destination by remember { mutableStateOf("") }
    var pending by remember { mutableStateOf<FilesCommand?>(null) }
    var markdown by remember { mutableStateOf(false) }
    val buffers by store.fileBuffers.collectAsState()
    val document = view.document
    val buffer = buffers[view.document_key]
    val text = buffer?.text ?: document?.content.orEmpty()
    val dirty = buffer != null && buffer.text != buffer.original
    fun send(command: FilesCommand) =
        store.command(Command(files = command.copy(scope = MobileStore.FILES_SCOPE)))
    fun leave(command: FilesCommand) {
        if (dirty) pending = command else send(command)
    }
    LaunchedEffect(view.document_key, document?.revision) {
        document?.let { store.syncFileBuffer(view.document_key, it.content) }
    }
    Column(Modifier.fillMaxSize()) {
        if (!inConversation) {
            PageHeader(
                "Files",
                view.directory.ifEmpty { "Project workspace" },
                back = { store.navigate(MobileTab.TOOLS) },
            ) {
                IconButton(onClick = { send(FilesCommand(load = FilesPath())) }) {
                    Icon(Icons.Outlined.Refresh, "Refresh files")
                }
                IconButton(onClick = { create = true }) {
                    Icon(Icons.Outlined.Add, "New file or folder")
                }
            }
            ProjectSelector(store)
        }
        if (view.listing_error.isNotEmpty())
            Notice(
                "Files unavailable",
                view.listing_error,
                { send(FilesCommand(load = FilesPath())) },
            )
        if (view.selected_path.isNotEmpty()) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = { leave(FilesCommand(close = Step())) }) {
                    Icon(Icons.Outlined.ArrowBack, "Back to files")
                }
                Text(
                    document?.name ?: view.selected_path,
                    Modifier.weight(1f),
                    style = MaterialTheme.typography.titleSmall,
                )
                if (document != null && FilePaths.renderer(document) == FilePaths.Renderer.MARKDOWN)
                    IconButton(onClick = { markdown = !markdown }) {
                        Icon(
                            if (markdown) Icons.Outlined.Edit else Icons.Outlined.Visibility,
                            if (markdown) "Edit Markdown" else "Preview Markdown",
                        )
                    }
                TextButton(
                    onClick = {
                        val key = view.document_key
                        val saved = text
                        store.action {
                            val result =
                                store.core.dispatch(
                                    Command(
                                        files =
                                            FilesCommand(
                                                scope = MobileStore.FILES_SCOPE,
                                                save = FilesText(saved),
                                            )
                                    )
                                )
                            result.file_document?.let { store.savedFileBuffer(key, it.content) }
                        }
                    },
                    enabled = document != null && !document.binary && !view.saving && dirty,
                ) {
                    Text(if (view.saving) "Saving…" else "Save")
                }
            }
            if (view.conflict)
                Notice(
                    "File changed on disk",
                    "Your edits are kept. Reload the current revision before saving again.",
                    { leave(FilesCommand(reload = Step())) },
                    "Reload",
                    true,
                )
            if (view.document_error.isNotEmpty())
                Text(view.document_error, color = colors.error, modifier = Modifier.padding(16.dp))
            if (view.document_loading) LinearProgressIndicator(Modifier.fillMaxWidth())
            if (document?.binary == true)
                Column(Modifier.padding(24.dp)) {
                    Text(document.mime_type.ifEmpty { "Binary file" })
                    Text("${document.size} bytes")
                    Button(
                        onClick = {
                            previewAttachment(
                                com.dbpprt.dieter.core.composition.Attachments.part(
                                    document.name,
                                    document.mime_type,
                                    com.dbpprt.dieter.core.files.FilePaths.bytes(document),
                                )
                            )
                        }
                    ) {
                        Text("Open preview")
                    }
                }
            else if (markdown)
                Column(
                    Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)
                ) {
                    RichText(text, {})
                }
            else
                MobileTextField(
                    text,
                    { store.editFileBuffer(view.document_key, document?.content.orEmpty(), it) },
                    Modifier.fillMaxSize().padding(12.dp),
                    textStyle =
                        MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                )
        } else {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                IconButton(
                    onClick = { send(FilesCommand(back = Step())) },
                    enabled = view.can_go_back,
                ) {
                    Icon(Icons.Outlined.ArrowBack, "Previous folder")
                }
                IconButton(
                    onClick = { send(FilesCommand(forward = Step())) },
                    enabled = view.can_go_forward,
                ) {
                    Icon(Icons.Outlined.ArrowForward, "Next folder")
                }
                IconButton(onClick = { send(FilesCommand(parent = Step())) }) {
                    Icon(Icons.Outlined.ArrowUpward, "Parent folder")
                }
                Text(
                    view.directory.ifEmpty { "/" },
                    Modifier.weight(1f),
                    style = MaterialTheme.typography.bodySmall,
                    maxLines = 1,
                )
                IconButton(
                    onClick = { send(FilesCommand(show_hidden = Toggle(!view.show_hidden))) }
                ) {
                    Icon(
                        if (view.show_hidden) Icons.Outlined.Visibility
                        else Icons.Outlined.VisibilityOff,
                        "Toggle hidden files",
                    )
                }
            }
            if (view.listing_loading) LinearProgressIndicator(Modifier.fillMaxWidth())
            LazyColumn {
                items(view.entries, key = { it.path }) { entry ->
                    ListItem(
                        headlineContent = { Text(entry.name) },
                        leadingContent = {
                            Icon(
                                if (entry.kind == "directory") Icons.Outlined.Folder
                                else Icons.Outlined.Description,
                                null,
                            )
                        },
                        supportingContent = {
                            Text(if (entry.kind == "directory") "Folder" else "${entry.size} bytes")
                        },
                        trailingContent = {
                            IconButton(
                                onClick = {
                                    entryActions = entry
                                    destination = entry.path
                                }
                            ) {
                                Icon(Icons.Outlined.MoreHoriz, "Actions for ${entry.name}")
                            }
                        },
                        modifier =
                            Modifier.clickable {
                                send(
                                    if (entry.kind == "directory")
                                        FilesCommand(navigate = FilesPath(entry.path))
                                    else FilesCommand(open_ = FilesPath(entry.path))
                                )
                            },
                    )
                }
            }
        }
    }
    if (create)
        AlertDialog(
            onDismissRequest = { create = false },
            title = { Text("New file or folder") },
            text = {
                Column {
                    MobileTextField(name, { name = it }, label = { Text("Name") })
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(directory, { directory = it })
                        Text("Folder")
                    }
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        send(FilesCommand(create = FilesCreate(name, directory)))
                        create = false
                    },
                    enabled = name.isNotBlank(),
                ) {
                    Text("Create")
                }
            },
            dismissButton = { TextButton(onClick = { create = false }) { Text("Cancel") } },
        )
    entryActions?.let { entry ->
        if (!moving && !deleting)
            AlertDialog(
                onDismissRequest = { entryActions = null },
                title = { Text(entry.name) },
                text = {
                    Column {
                        TextButton(onClick = { moving = true }) { Text("Rename or move") }
                        TextButton(onClick = { deleting = true }) {
                            Text("Delete", color = colors.error)
                        }
                    }
                },
                confirmButton = { TextButton(onClick = { entryActions = null }) { Text("Close") } },
            )
        if (moving)
            AlertDialog(
                onDismissRequest = { moving = false },
                title = { Text("Rename or move") },
                text = {
                    MobileTextField(
                        destination,
                        { destination = it },
                        label = { Text("Path relative to workspace") },
                    )
                },
                confirmButton = {
                    TextButton(
                        onClick = {
                            send(FilesCommand(move = FilesMove(entry.path, destination)))
                            moving = false
                            entryActions = null
                        },
                        enabled = FilePaths.normalize(destination).isSuccess,
                    ) {
                        Text("Move")
                    }
                },
                dismissButton = { TextButton(onClick = { moving = false }) { Text("Cancel") } },
            )
        if (deleting)
            AlertDialog(
                onDismissRequest = { deleting = false },
                title = { Text("Delete ${entry.name}?") },
                text = {
                    Text(
                        if (entry.kind == "directory") "This deletes the folder and its contents."
                        else "This deletes the file from the workspace."
                    )
                },
                confirmButton = {
                    TextButton(
                        onClick = {
                            send(
                                FilesCommand(
                                    delete = FilesDelete(entry.path, entry.kind == "directory")
                                )
                            )
                            deleting = false
                            entryActions = null
                        }
                    ) {
                        Text("Delete", color = colors.error)
                    }
                },
                dismissButton = { TextButton(onClick = { deleting = false }) { Text("Cancel") } },
            )
    }
    pending?.let { next ->
        AlertDialog(
            onDismissRequest = { pending = null },
            title = { Text("Discard unsaved edits?") },
            text = { Text("Your changes to ${document?.name.orEmpty()} have not been saved.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        store.discardFileBuffer(view.document_key)
                        send(next)
                        pending = null
                    }
                ) {
                    Text("Discard edits")
                }
            },
            dismissButton = { TextButton(onClick = { pending = null }) { Text("Keep editing") } },
        )
    }
}

@Composable
internal fun MachinesScreen(store: MobileStore) {
    val session by store.session.collectAsState()
    val telemetry by store.telemetry.collectAsState()
    var selected by rememberSaveable { mutableStateOf("") }
    var operation by remember { mutableStateOf<MachineOperationState?>(null) }
    var rename by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }
    val machine = session.machines.firstOrNull { it.id == selected }
    val readings = telemetry.machines[selected]
    Column {
        PageHeader(
            if (machine != null) machine.display_name else "Machines",
            session.phase_label,
            back = {
                if (machine != null) {
                    selected = ""
                    store.command(Command(telemetry = TelemetryCommand(select = TelemetrySelect())))
                } else store.navigate(MobileTab.TOOLS)
            },
        ) {
            if (machine != null)
                IconButton(
                    onClick = {
                        name = machine.display_name
                        rename = true
                    }
                ) {
                    Icon(Icons.Outlined.Edit, "Rename machine")
                }
            else IconButton(onClick = store::retry) { Icon(Icons.Outlined.Refresh, "Reconnect") }
        }
        LazyColumn(
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (machine == null)
                items(session.machines, key = { it.id }) { item ->
                    Surface(
                        onClick = {
                            selected = item.id
                            store.command(
                                Command(
                                    telemetry =
                                        TelemetryCommand(select = TelemetrySelect(item.id, true))
                                )
                            )
                        },
                        shape = RoundedCornerShape(14.dp),
                        color = colors.surfaceContainerHigh,
                    ) {
                        Row(
                            Modifier.fillMaxWidth().padding(16.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(Icons.Outlined.Computer, null)
                            Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f)) {
                                Text(
                                    item.display_name,
                                    style = MaterialTheme.typography.titleSmall,
                                    fontWeight = FontWeight.SemiBold,
                                )
                                Text(
                                    item.detail,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = colors.onSurfaceVariant,
                                )
                                Text(
                                    item.presence +
                                        if (item.route.isNotEmpty()) " · ${item.route}" else "",
                                    style = MaterialTheme.typography.labelSmall,
                                )
                            }
                            Icon(Icons.Outlined.ChevronRight, null)
                        }
                    }
                }
            else {
                item {
                    FormSection("Connection") {
                        Text(machine.detail)
                        Text(machine.route, style = MaterialTheme.typography.bodySmall)
                        Text(
                            "Dieter ${machine.release_version}",
                            style = MaterialTheme.typography.bodySmall,
                        )
                        if (machine.privacy_label.isNotEmpty())
                            Text(machine.privacy_label, style = MaterialTheme.typography.bodySmall)
                    }
                }
                readings?.information?.let { information ->
                    item {
                        FormSection("System") {
                            Text(
                                listOf(
                                        information.os_name,
                                        information.os_version,
                                        information.architecture,
                                    )
                                    .joinToString(" · ")
                            )
                            Text(information.hardware_model)
                            Text(information.processor, style = MaterialTheme.typography.bodySmall)
                            Text(
                                "${information.logical_cpu_count} cores · ${information.active_agent_count} active agents",
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                    }
                    item {
                        FormSection("CPU") {
                            Text(
                                "${information.cpu_usage_percent.toInt()}%",
                                style = MaterialTheme.typography.headlineMedium,
                            )
                            LinearProgressIndicator(
                                progress = {
                                    (information.cpu_usage_percent / 100).toFloat().coerceIn(0f, 1f)
                                },
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                    }
                    item {
                        FormSection("Memory") {
                            Text(
                                "${information.memory_used_bytes / 1_073_741_824L} / ${information.memory_total_bytes / 1_073_741_824L} GB"
                            )
                            if (information.memory_total_bytes > 0)
                                LinearProgressIndicator(
                                    progress = {
                                        information.memory_used_bytes.toFloat() /
                                            information.memory_total_bytes
                                    },
                                    modifier = Modifier.fillMaxWidth(),
                                )
                        }
                    }
                    item {
                        FormSection("Storage") {
                            Text("${information.disk_free_bytes / 1_073_741_824L} GB free")
                            Text(
                                "${information.network_receive_bytes_per_second.toInt()} B/s down · ${information.network_send_bytes_per_second.toInt()} B/s up",
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                    }
                    items(information.processes.take(30), key = { it.pid }) { process ->
                        ListItem(
                            headlineContent = { Text(process.name) },
                            supportingContent = { Text("PID ${process.pid}") },
                        )
                    }
                }
                readings?.operations?.let { operations ->
                    item {
                        FormSection("Machine actions") {
                            operations.forEach { state ->
                                val copy =
                                    com.dbpprt.dieter.core.client.rules.MachineExports
                                        .operationCopy(state.action.value)
                                TextButton(
                                    onClick = { operation = state },
                                    enabled = state.available && !telemetry.operation_pending,
                                ) {
                                    Text(copy.menu_title)
                                }
                                if (!state.available && state.unavailable_reason.isNotEmpty())
                                    Text(
                                        state.unavailable_reason,
                                        style = MaterialTheme.typography.bodySmall,
                                    )
                            }
                            if (telemetry.operation_pending)
                                LinearProgressIndicator(Modifier.fillMaxWidth())
                            if (telemetry.operation_result.isNotEmpty())
                                Text(telemetry.operation_result)
                        }
                    }
                }
                if (readings?.loading == true)
                    item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
                readings
                    ?.error
                    ?.takeIf { it.isNotEmpty() }
                    ?.let { failure ->
                        item {
                            Notice(
                                "Telemetry unavailable",
                                failure,
                                {
                                    store.command(
                                        Command(
                                            telemetry =
                                                TelemetryCommand(
                                                    select = TelemetrySelect(selected, true)
                                                )
                                        )
                                    )
                                },
                            )
                        }
                    }
            }
        }
    }
    operation?.let { state ->
        val copy =
            com.dbpprt.dieter.core.client.rules.MachineExports.operationCopy(state.action.value)
        AlertDialog(
            onDismissRequest = { operation = null },
            title = { Text(copy.title) },
            text = { Text(copy.explanation) },
            confirmButton = {
                TextButton(
                    onClick = {
                        store.command(
                            Command(
                                telemetry =
                                    TelemetryCommand(perform = TelemetryOperation(state.action))
                            )
                        )
                        operation = null
                    }
                ) {
                    Text(
                        copy.button,
                        color = if (copy.destructive) colors.error else colors.primary,
                    )
                }
            },
            dismissButton = { TextButton(onClick = { operation = null }) { Text("Cancel") } },
        )
    }
    if (rename && machine != null)
        AlertDialog(
            onDismissRequest = { rename = false },
            title = { Text("Rename machine") },
            text = { MobileTextField(name, { name = it }, label = { Text("Machine name") }) },
            confirmButton = {
                TextButton(
                    onClick = {
                        store.command(Command(rename_machine = RenameMachine(selected, name)))
                        rename = false
                    },
                    enabled = name.isNotBlank(),
                ) {
                    Text("Save")
                }
            },
            dismissButton = { TextButton(onClick = { rename = false }) { Text("Cancel") } },
        )
}

@Composable
internal fun UsageScreen(store: MobileStore) {
    val view by store.quotas.collectAsState()
    var reset by remember { mutableStateOf<QuotaAccountRow?>(null) }
    Column {
        PageHeader("Usage", "Provider accounts", back = { store.navigate(MobileTab.TOOLS) }) {
            IconButton(
                onClick = {
                    store.command(Command(quotas = QuotasCommand(load = QuotasLoad(true))))
                }
            ) {
                Icon(Icons.Outlined.Refresh, "Refresh usage")
            }
        }
        if (view.error.isNotEmpty())
            Notice(
                "Usage unavailable",
                view.error,
                { store.command(Command(quotas = QuotasCommand(load = QuotasLoad()))) },
            )
        if (view.loading) LinearProgressIndicator(Modifier.fillMaxWidth())
        LazyColumn(
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            view.group_rows.forEach { group ->
                item {
                    Text(
                        group.provider_name + " · " + group.summary,
                        style = MaterialTheme.typography.titleMedium,
                    )
                }
                items(group.accounts, key = { it.account_key }) { account ->
                    FormSection(account.identity) {
                        Text(
                            account.subtitle,
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.onSurfaceVariant,
                        )
                        if (account.remaining >= 0) {
                            Text("${account.remaining}% remaining")
                            LinearProgressIndicator(
                                progress = { account.remaining / 100f },
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                        Text(
                            account.status.ifEmpty { account.unavailable },
                            style = MaterialTheme.typography.bodySmall,
                        )
                        account.windows.forEach { window ->
                            Text(
                                window.name +
                                    " · " +
                                    (if (window.remaining >= 0) "${window.remaining}% remaining"
                                    else "Not reported") +
                                    if (window.resets_at.isNotEmpty())
                                        " · Resets ${window.resets_at}"
                                    else "",
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                        account.details
                            .filter { !it.monetary }
                            .forEach {
                                Text(
                                    "${it.label} · ${it.text}",
                                    style = MaterialTheme.typography.bodySmall,
                                )
                            }
                        account.machines.forEach {
                            Text(
                                "${it.name} · ${it.state}",
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                        if (account.can_reset)
                            TextButton(
                                onClick = { reset = account },
                                enabled = account.account_key !in view.mutating,
                            ) {
                                Text("Use reset credit…")
                            }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("Include in summary", Modifier.weight(1f))
                            Switch(
                                account.included,
                                {
                                    store.command(
                                        Command(
                                            quotas =
                                                QuotasCommand(
                                                    set_included =
                                                        QuotaInclusion(
                                                            group.provider,
                                                            account.account_key,
                                                            it,
                                                        )
                                                )
                                        )
                                    )
                                },
                                enabled = account.account_key !in view.mutating,
                            )
                        }
                    }
                }
            }
            if (!view.loading && view.group_rows.isEmpty())
                item {
                    Box(Modifier.height(200.dp)) {
                        Empty(
                            "No provider usage",
                            "Accounts report their usage through an enrolled machine.",
                        )
                    }
                }
        }
    }
    reset?.let { account ->
        AlertDialog(
            onDismissRequest = { reset = null },
            title = { Text("Use a reset credit?") },
            text = { Text("This spends one reset credit for ${account.identity}.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        store.command(
                            Command(
                                quotas =
                                    QuotasCommand(consume_reset = QuotaAccount(account.account_key))
                            )
                        )
                        reset = null
                    }
                ) {
                    Text("Use reset credit")
                }
            },
            dismissButton = { TextButton(onClick = { reset = null }) { Text("Cancel") } },
        )
    }
}

@Composable
internal fun SettingsScreen(store: MobileStore) {
    val session by store.session.collectAsState()
    val palette by store.palette.collectAsState()
    val appearance by store.appearance.collectAsState()
    val outbox by store.outbox.collectAsState()
    var category by rememberSaveable { mutableStateOf("Display") }
    var signOut by remember { mutableStateOf(false) }
    var gatewayEditor by remember { mutableStateOf(false) }
    var gatewayName by remember { mutableStateOf("") }
    var gatewayUrl by remember { mutableStateOf("") }
    var removingGateway by remember { mutableStateOf<GatewayEntry?>(null) }
    Column {
        PageHeader("Settings", back = { store.navigate(MobileTab.TOOLS) })
        TabRow(if (category == "Display") 0 else 1) {
            listOf("Display", "Connections").forEach { title ->
                Tab(category == title, { category = title }, text = { Text(title) })
            }
        }
        LazyColumn(
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (category == "Display") {
                item {
                    FormSection("Appearance") {
                        ChoiceChip(
                            appearance.replaceFirstChar(Char::uppercase),
                            listOf("system" to "System", "light" to "Light", "dark" to "Dark"),
                            onSelect = store::setAppearance,
                        )
                    }
                }
                item {
                    FormSection("Color palette") {
                        FlowRow(
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            DieterPalette.entries.forEach { item ->
                                FilterChip(
                                    palette == item,
                                    { store.setPalette(item) },
                                    label = { Text(item.displayName) },
                                )
                            }
                        }
                    }
                }
                item {
                    FormSection("Conversation") {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("Show reasoning", Modifier.weight(1f))
                            Switch(
                                session.show_reasoning,
                                {
                                    store.command(
                                        Command(set_show_reasoning = SetShowReasoning(it))
                                    )
                                },
                            )
                        }
                    }
                }
            } else {
                item {
                    FormSection("Dieter connection") {
                        Text(session.gateway_origin)
                        Text(session.phase_label)
                        Text(session.error, style = MaterialTheme.typography.bodySmall)
                        Row {
                            TextButton(onClick = store::retry) { Text("Reconnect") }
                            TextButton(
                                onClick = {
                                    store.command(
                                        Command(
                                            set_connected =
                                                SetConnected(
                                                    session.phase ==
                                                        SessionSlice.Phase.PHASE_DISCONNECTED
                                                )
                                        )
                                    )
                                }
                            ) {
                                Text(
                                    if (session.phase == SessionSlice.Phase.PHASE_DISCONNECTED)
                                        "Connect"
                                    else "Disconnect"
                                )
                            }
                        }
                    }
                }
                items(session.gateways, key = { it.origin }) { gateway ->
                    ListItem(
                        headlineContent = { Text(gateway.name.ifEmpty { gateway.origin }) },
                        supportingContent = { Text(gateway.origin) },
                        trailingContent = {
                            if (gateway.active) Icon(Icons.Outlined.Check, "Active gateway")
                        },
                        modifier =
                            Modifier.clickable {
                                store.command(
                                    Command(select_gateway = SelectGateway(gateway.origin))
                                )
                            },
                    )
                }
                item {
                    Row {
                        TextButton(
                            onClick = {
                                gatewayName = ""
                                gatewayUrl = ""
                                gatewayEditor = true
                            }
                        ) {
                            Text("Add gateway")
                        }
                        TextButton(
                            onClick = {
                                gatewayName =
                                    session.gateways.firstOrNull { it.active }?.name.orEmpty()
                                gatewayUrl = session.gateway_origin
                                gatewayEditor = true
                            }
                        ) {
                            Text("Edit active gateway")
                        }
                        TextButton(
                            onClick = {
                                removingGateway = session.gateways.firstOrNull { it.active }
                            },
                            enabled = session.gateways.size > 1,
                        ) {
                            Text("Remove active gateway")
                        }
                    }
                }
                outbox.machines.forEach { machine ->
                    item {
                        FormSection(machine.title) {
                            Text(machine.detail, style = MaterialTheme.typography.bodySmall)
                            if (machine.retry_title.isNotEmpty())
                                TextButton(
                                    onClick = {
                                        store.command(
                                            Command(
                                                retry_pending =
                                                    RetryPending(daemon_id = machine.daemon_id)
                                            )
                                        )
                                    }
                                ) {
                                    Text(machine.retry_title)
                                }
                        }
                    }
                }
                items(outbox.failed_operations, key = { it.id }) { failure ->
                    FormSection(failure.label) {
                        Text(failure.failure, color = colors.error)
                        Row {
                            TextButton(
                                onClick = {
                                    store.command(Command(retry_pending = RetryPending(failure.id)))
                                }
                            ) {
                                Text("Retry")
                            }
                            TextButton(
                                onClick = {
                                    store.command(
                                        Command(discard_pending = DiscardPending(failure.id))
                                    )
                                }
                            ) {
                                Text("Discard")
                            }
                        }
                    }
                }
                item { OutlinedButton(onClick = { signOut = true }) { Text("Sign out") } }
            }
        }
    }
    if (gatewayEditor)
        AlertDialog(
            onDismissRequest = { gatewayEditor = false },
            title = { Text("Gateway") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    MobileTextField(gatewayName, { gatewayName = it }, label = { Text("Name") })
                    MobileTextField(
                        gatewayUrl,
                        { gatewayUrl = it },
                        label = { Text("Gateway URL") },
                        singleLine = true,
                    )
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        store.action {
                            store.core.dispatch(
                                Command(use_gateway = UseGateway(gatewayUrl, gatewayName))
                            )
                            gatewayEditor = false
                        }
                    },
                    enabled = gatewayUrl.isNotBlank(),
                ) {
                    Text("Save")
                }
            },
            dismissButton = { TextButton(onClick = { gatewayEditor = false }) { Text("Cancel") } },
        )
    removingGateway?.let { gateway ->
        AlertDialog(
            onDismissRequest = { removingGateway = null },
            title = { Text("Remove gateway?") },
            text = { Text(gateway.origin) },
            confirmButton = {
                TextButton(
                    onClick = {
                        store.command(Command(remove_gateway = RemoveGateway(gateway.origin)))
                        removingGateway = null
                    }
                ) {
                    Text("Remove")
                }
            },
            dismissButton = { TextButton(onClick = { removingGateway = null }) { Text("Cancel") } },
        )
    }
    if (signOut)
        AlertDialog(
            onDismissRequest = { signOut = false },
            title = { Text("Sign out of Dieter?") },
            text = {
                Text(
                    "This clears this device’s cached workspace, unsent work, and drafts for this account."
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        store.command(Command(sign_out = SignOut()))
                        signOut = false
                    }
                ) {
                    Text("Sign out")
                }
            },
            dismissButton = { TextButton(onClick = { signOut = false }) { Text("Cancel") } },
        )
}

@Composable
internal fun ScreensScreen(store: MobileStore) {
    val session by store.session.collectAsState()
    val selected by store.selectedScreen.collectAsState()
    if (selected.isNotEmpty()) {
        NativeScreen(store, Modifier.fillMaxSize())
        return
    }
    Column {
        PageHeader(
            "Screens",
            "Share an enrolled machine’s screen",
            back = { store.navigate(MobileTab.TOOLS) },
        )
        LazyColumn {
            items(session.machines, key = { it.id }) { machine ->
                ListItem(
                    headlineContent = { Text(machine.display_name) },
                    supportingContent = { Text(machine.screen_status) },
                    leadingContent = { Icon(Icons.Outlined.DesktopWindows, null) },
                    modifier =
                        Modifier.clickable(enabled = machine.can_share_screen) {
                            store.openNativeScreen(machine.id)
                        },
                )
            }
        }
    }
}

@Composable
internal fun TerminalsScreen(store: MobileStore, inConversation: Boolean = false) {
    val view by store.terminals.collectAsState()
    val local by store.cardTerminals.collectAsState()
    val selected by store.visibleTerminal.collectAsState()
    val acceptsInput by store.terminalAcceptsInput.collectAsState()
    var create by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<com.dbpprt.dieter.api.v1.Terminal?>(null) }
    var closing by remember { mutableStateOf<com.dbpprt.dieter.api.v1.Terminal?>(null) }
    var name by remember { mutableStateOf("") }
    var shell by remember { mutableStateOf("") }
    val entries =
        if (inConversation)
            local.terminals.map { terminal ->
                OverviewTerminal(
                    id = terminal.id,
                    terminal = terminal,
                    row = local.rows.firstOrNull { it.id == terminal.id },
                )
            }
        else view.entries
    fun send(value: TerminalsCommand) =
        store.command(Command(terminals = value.copy(scope = MobileStore.TERMINAL_SCOPE)))
    Column {
        PageHeader(
            "Terminal",
            if (inConversation) local.status else view.status,
            back = if (inConversation) null else ({ store.navigate(MobileTab.TOOLS) }),
        ) {
            IconButton(
                onClick = {
                    name = ""
                    shell = ""
                    create = true
                }
            ) {
                Icon(Icons.Outlined.Add, "New terminal")
            }
        }
        DisposableEffect(store) {
            store.command(
                Command(
                    terminals =
                        TerminalsCommand(scope = MobileStore.TERMINAL_SCOPE, active = Toggle(true))
                )
            )
            onDispose {
                store.command(
                    Command(
                        terminals =
                            TerminalsCommand(
                                scope = MobileStore.TERMINAL_SCOPE,
                                active = Toggle(false),
                            )
                    )
                )
            }
        }
        if (local.error.isNotEmpty())
            Text(local.error, Modifier.padding(12.dp), color = colors.error)
        if (selected.isNotEmpty()) {
            NativeTerminal(store, Modifier.weight(1f))
            Row(Modifier.horizontalScroll(rememberScrollState())) {
                listOf(
                        "Esc" to TerminalKey.TERMINAL_KEY_ESCAPE,
                        "Tab" to TerminalKey.TERMINAL_KEY_TAB,
                        "↑" to TerminalKey.TERMINAL_KEY_UP,
                        "↓" to TerminalKey.TERMINAL_KEY_DOWN,
                        "←" to TerminalKey.TERMINAL_KEY_LEFT,
                        "→" to TerminalKey.TERMINAL_KEY_RIGHT,
                    )
                    .forEach { (label, key) ->
                        TextButton(
                            onClick = {
                                store.terminalKeys.tryEmit(key)
                            },
                            enabled = acceptsInput,
                        ) {
                            Text(label)
                        }
                    }
                TextButton(
                    onClick = { store.terminalInput(byteArrayOf(3)) },
                    enabled = acceptsInput,
                ) {
                    Text("Ctrl C")
                }
            }
        }
        LazyColumn(Modifier.heightIn(max = 240.dp)) {
            items(entries, key = { it.id }) { entry ->
                ListItem(
                    headlineContent = { Text(entry.terminal?.name.orEmpty()) },
                    supportingContent = {
                        Text(
                            listOf(entry.machine_name, entry.row?.status.orEmpty())
                                .filter { it.isNotBlank() }
                                .joinToString(" · ")
                        )
                    },
                    leadingContent = { Icon(Icons.Outlined.Terminal, null) },
                    trailingContent = {
                        if (entry.id == selected)
                            Row {
                                IconButton(
                                    onClick = {
                                        editing = entry.terminal
                                        name = entry.terminal?.name.orEmpty()
                                    }
                                ) {
                                    Icon(Icons.Outlined.Edit, "Rename terminal")
                                }
                                IconButton(onClick = { closing = entry.terminal }) {
                                    Icon(Icons.Outlined.Close, "Close terminal")
                                }
                            }
                    },
                    modifier =
                        Modifier.clickable {
                            if (inConversation)
                                send(TerminalsCommand(select = TerminalId(entry.id)))
                            else
                                store.command(
                                    Command(
                                        terminal_overview =
                                            TerminalOverviewCommand(
                                                scope = MobileStore.TERMINAL_SCOPE,
                                                select = TerminalId(entry.id),
                                            )
                                    )
                                )
                        },
                )
            }
        }
        if (entries.isEmpty())
            Box(Modifier.weight(1f)) {
                Empty(
                    "No terminals",
                    "Persistent shells stay on the machine when this app disconnects.",
                )
            }
    }
    if (create && !inConversation) TerminalEditor(store) { create = false }
    if (create && inConversation)
        AlertDialog(
            onDismissRequest = { create = false },
            title = { Text("New terminal") },
            text = {
                Column {
                    MobileTextField(name, { name = it }, label = { Text("Terminal name") })
                    MobileTextField(
                        shell,
                        { shell = it },
                        label = { Text("Shell (default if empty)") },
                    )
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        send(TerminalsCommand(create = CreateTerminal(name = name, shell = shell)))
                        create = false
                    }
                ) {
                    Text("Create")
                }
            },
            dismissButton = { TextButton(onClick = { create = false }) { Text("Cancel") } },
        )
    editing?.let { terminal ->
        AlertDialog(
            onDismissRequest = { editing = null },
            title = { Text("Rename terminal") },
            text = { MobileTextField(name, { name = it }, label = { Text("Terminal name") }) },
            confirmButton = {
                TextButton(
                    onClick = {
                        send(TerminalsCommand(rename = TerminalRename(terminal.id, name)))
                        editing = null
                    },
                    enabled = name.isNotBlank(),
                ) {
                    Text("Save")
                }
            },
            dismissButton = { TextButton(onClick = { editing = null }) { Text("Cancel") } },
        )
    }
    closing?.let { terminal ->
        AlertDialog(
            onDismissRequest = { closing = null },
            title = { Text("Close ${terminal.name}?") },
            text = {
                Text(
                    entries.firstOrNull { it.terminal?.id == terminal.id }?.row?.close_message
                        ?: "This ends the shell and clears its scrollback."
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        send(TerminalsCommand(close = TerminalId(terminal.id)))
                        closing = null
                    }
                ) {
                    Text("Close terminal")
                }
            },
            dismissButton = { TextButton(onClick = { closing = null }) { Text("Cancel") } },
        )
    }
}
