@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.dbpprt.dieter.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.core.files.FilePaths
import com.dbpprt.dieter.settings.DieterPalette

/** "Project" and "Checkout" menus for project-scoped tools. */
internal fun projectScopeMenu(store: MobileStore, rebind: () -> Unit): List<ChromeAction> {
    val workspace = store.workspace.value
    val current = store.currentProjectId()
    val project = workspace.projects.firstOrNull { it.id == current }
    val checkout =
        store.selectedCheckout.value
            .ifEmpty { store.creationDefaults.value.checkouts[current].orEmpty() }
            .ifEmpty { project?.checkouts?.singleOrNull()?.id.orEmpty() }
    val machines = store.session.value.machines
    return listOfNotNull(
        ChromeAction(
            "scope-project",
            "Project",
            Glyph.FOLDER,
            subtitle = project?.name.orEmpty(),
            menu =
                listOf(
                    MenuSection(
                        workspace.projects.map { item ->
                            ChromeAction(
                                "scope-project-${item.id}",
                                item.name,
                                checked = item.id == current,
                            ) {
                                store.selectedProject.value = item.id
                                store.selectedCheckout.value = ""
                                rebind()
                            }
                        }
                    )
                ),
        ),
        if ((project?.checkouts?.size ?: 0) > 1)
            ChromeAction(
                "scope-checkout",
                "Checkout",
                Glyph.MACHINE,
                menu =
                    listOf(
                        MenuSection(
                            project!!.checkouts.map { item ->
                                ChromeAction(
                                    "scope-checkout-${item.id}",
                                    (machines.firstOrNull { it.id == item.daemon_id }?.display_name
                                        ?: item.name) + " · " + item.name,
                                    checked = item.id == checkout,
                                ) {
                                    store.selectedCheckout.value = item.id
                                    rebind()
                                }
                            }
                        )
                    ),
            )
        else null,
    )
}

// ---------------------------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------------------------

private fun String.trimSlashes() = trim('/').trim()

@Composable
internal fun FilesScreen(
    store: MobileStore,
    inConversation: Boolean = false,
    route: MobileRoute.FilePath? = null,
) {
    if (route?.file == true) {
        DocumentScreen(store, route)
        return
    }
    val view by store.files.collectAsState()
    val conversation by store.conversation.collectAsState()
    val workspace by store.workspace.collectAsState()
    var create by remember { mutableStateOf<Boolean?>(null) }
    var moving by remember { mutableStateOf<com.dbpprt.dieter.api.v1.FileEntry?>(null) }
    var deleting by remember { mutableStateOf<com.dbpprt.dieter.api.v1.FileEntry?>(null) }
    val buffers by store.fileBuffers.collectAsState()
    val path = route?.path.orEmpty()
    val ready = route == null || view.directory.trimSlashes() == path.trimSlashes()
    val cardId = if (inConversation) store.selectedCard.value else ""
    val title = path.trimSlashes().substringAfterLast('/').ifEmpty { "Files" }
    val subtitle =
        if (inConversation) conversation.card?.title.orEmpty()
        else workspace.projects.firstOrNull { it.id == store.currentProjectId() }?.name.orEmpty()
    val chrome =
        ScreenChrome(
            title,
            subtitle = subtitle,
            actions =
                listOf(
                    ChromeAction(
                        "files-menu",
                        "File actions",
                        Glyph.MORE_HORIZONTAL,
                        menu =
                            listOfNotNull(
                                MenuSection(
                                    listOf(
                                        ChromeAction("new-file", "New file", Glyph.FILE) {
                                            create = false
                                        },
                                        ChromeAction("new-folder", "New folder", Glyph.FOLDER_ADD) {
                                            create = true
                                        },
                                    )
                                ),
                                MenuSection(
                                    listOf(
                                        ChromeAction(
                                            "hidden",
                                            "Show hidden files",
                                            Glyph.EYE,
                                            checked = view.show_hidden,
                                        ) {
                                            store.filesCommand(
                                                FilesCommand(
                                                    show_hidden = Toggle(!view.show_hidden)
                                                )
                                            )
                                        },
                                        ChromeAction("refresh-files", "Refresh", Glyph.REFRESH) {
                                            store.filesCommand(FilesCommand(load = FilesPath(path)))
                                        },
                                    )
                                ),
                                if (!inConversation && route == null)
                                    MenuSection(projectScopeMenu(store) { store.bindFiles() })
                                else null,
                            ),
                    )
                ),
        )
    Screen(chrome) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("files-list"),
            state = listState,
            contentPadding = padding,
        ) {
            if (view.listing_error.isNotEmpty())
                item("error") {
                    Banner(
                        "Files unavailable",
                        view.listing_error,
                        Modifier.padding(horizontal = ScreenMargin, vertical = 8.dp),
                        tone = Tone.DANGER,
                        actionLabel = "Retry",
                        onAction = { store.filesCommand(FilesCommand(load = FilesPath(path))) },
                    )
                }
            if (!ready || (view.listing_loading && view.entries.isEmpty()))
                item("loading") {
                    Box(
                        Modifier.fillMaxWidth().padding(48.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Spinner(Modifier.size(26.dp))
                    }
                }
            else {
                item("top") { Spacer(Modifier.height(8.dp)) }
                val entries = view.entries
                if (entries.isEmpty() && view.listing_error.isEmpty())
                    item("empty") {
                        EmptyState(
                            Glyph.FOLDER,
                            "Empty folder",
                            "Create a file or folder from the menu.",
                            Modifier.padding(top = 40.dp),
                        )
                    }
                itemsIndexed(entries, key = { _, entry -> entry.path }) { index, entry ->
                    val folder = entry.kind == "directory"
                    val menu = rememberMenuState()
                    val edited =
                        buffers.entries.any {
                            it.key.endsWith(entry.path) && it.value.text != it.value.original
                        }
                    val sections =
                        listOf(
                            MenuSection(
                                listOf(
                                    ChromeAction(
                                        "move-${entry.path}",
                                        "Rename or move…",
                                        Glyph.RENAME,
                                    ) {
                                        moving = entry
                                    },
                                    ChromeAction(
                                        "delete-${entry.path}",
                                        "Delete",
                                        Glyph.TRASH,
                                        destructive = true,
                                    ) {
                                        deleting = entry
                                    },
                                )
                            )
                        )
                    MenuAnchor(menu) {
                        ListRow(
                            entry.name,
                            Modifier.testTag("file-${entry.name}"),
                            position = Position.of(index, entries.size),
                            subtitle =
                                if (folder) null
                                else formatBytes(entry.size) + if (edited) " · Edited" else "",
                            glyph = if (folder) Glyph.FOLDER else Glyph.FILE,
                            glyphTint = if (folder) Color(0xFF1E9BF0) else palette.secondaryLabel,
                            accessory = if (folder) Accessory.CHEVRON else Accessory.NONE,
                            onClick = {
                                store.push(MobileRoute.FilePath(entry.path, !folder, cardId))
                            },
                            onLongClick = { menu.show(sections) },
                        )
                    }
                }
            }
        }
    }
    create?.let { directory ->
        PromptDialog(
            if (directory) "New folder" else "New file",
            "",
            "Create",
            { name ->
                store.filesCommand(
                    FilesCommand(
                        create =
                            FilesCreate(
                                if (path.isEmpty()) name else "${path.trimSlashes()}/$name",
                                directory,
                            )
                    )
                )
                create = null
            },
            { create = null },
            placeholder = if (directory) "Folder name" else "File name",
        )
    }
    moving?.let { entry ->
        PromptDialog(
            "Rename or move",
            entry.path,
            "Move",
            { destination ->
                if (FilePaths.normalize(destination).isSuccess)
                    store.filesCommand(FilesCommand(move = FilesMove(entry.path, destination)))
                moving = null
            },
            { moving = null },
            message = "Path relative to the workspace.",
        )
    }
    deleting?.let { entry ->
        ConfirmDialog(
            "Delete ${entry.name}?",
            if (entry.kind == "directory") "This deletes the folder and its contents."
            else "This deletes the file from the workspace.",
            "Delete",
            {
                store.filesCommand(
                    FilesCommand(delete = FilesDelete(entry.path, entry.kind == "directory"))
                )
                deleting = null
            },
            { deleting = null },
            destructive = true,
        )
    }
}

private fun formatBytes(size: Long): String =
    when {
        size < 1024 -> "$size bytes"
        size < 1024 * 1024 -> "${(size / 102.4).toInt() / 10.0} KB"
        else -> "${(size / 104857.6).toInt() / 10.0} MB"
    }

@Composable
private fun DocumentScreen(store: MobileStore, route: MobileRoute.FilePath) {
    val view by store.files.collectAsState()
    val buffers by store.fileBuffers.collectAsState()
    val previewAttachment = rememberAttachmentViewer { store.error.value = it }
    var markdown by remember(route.path) { mutableStateOf(route.path.endsWith(".md", true)) }
    var deleting by remember { mutableStateOf(false) }
    var moving by remember { mutableStateOf(false) }
    val document =
        view.document.takeIf { view.selected_path.trimSlashes() == route.path.trimSlashes() }
    val buffer = buffers[view.document_key]
    val text = buffer?.text ?: document?.content.orEmpty()
    val dirty = buffer != null && buffer.text != buffer.original
    val isMarkdown = document != null && FilePaths.renderer(document) == FilePaths.Renderer.MARKDOWN
    LaunchedEffect(view.document_key, document?.revision) {
        document?.let { store.syncFileBuffer(view.document_key, it.content) }
    }
    fun save() {
        val key = view.document_key
        val saved = text
        store.action {
            store.core
                .dispatch(
                    Command(
                        files =
                            FilesCommand(scope = MobileStore.FILES_SCOPE, save = FilesText(saved))
                    )
                )
                .file_document
                ?.let {
                    store.savedFileBuffer(key, it.content)
                }
        }
    }
    val chrome =
        ScreenChrome(
            route.path.substringAfterLast('/'),
            subtitle = if (dirty) "Edited" else route.path.substringBeforeLast('/', ""),
            confirm =
                if (document != null && !document.binary && (dirty || view.saving))
                    ChromeAction(
                        "save-file",
                        if (view.saving) "Saving…" else "Save",
                        null,
                        enabled = dirty && !view.saving,
                    ) {
                        save()
                    }
                else null,
            actions =
                listOf(
                    ChromeAction(
                        "document-menu",
                        "Document actions",
                        Glyph.MORE_HORIZONTAL,
                        menu =
                            listOfNotNull(
                                if (isMarkdown)
                                    MenuSection(
                                        listOf(
                                            ChromeAction(
                                                "preview-markdown",
                                                "Preview",
                                                Glyph.EYE,
                                                checked = markdown,
                                            ) {
                                                markdown = true
                                            },
                                            ChromeAction(
                                                "edit-markdown",
                                                "Edit",
                                                Glyph.EDIT,
                                                checked = !markdown,
                                            ) {
                                                markdown = false
                                            },
                                        )
                                    )
                                else null,
                                MenuSection(
                                    listOfNotNull(
                                        if (dirty)
                                            ChromeAction("discard", "Discard edits", Glyph.UNDO) {
                                                store.discardFileBuffer(view.document_key)
                                            }
                                        else null,
                                        if (view.conflict)
                                            ChromeAction(
                                                "reload",
                                                "Reload from disk",
                                                Glyph.REFRESH,
                                            ) {
                                                store.filesCommand(FilesCommand(reload = Step()))
                                            }
                                        else null,
                                        ChromeAction(
                                            "rename-file",
                                            "Rename or move…",
                                            Glyph.RENAME,
                                        ) {
                                            moving = true
                                        },
                                        ChromeAction(
                                            "delete-file",
                                            "Delete",
                                            Glyph.TRASH,
                                            destructive = true,
                                        ) {
                                            deleting = true
                                        },
                                    )
                                ),
                            ),
                    )
                ),
        )
    Screen(chrome) {
        Column(Modifier.fillMaxSize().imePadding().padding(top = padding.calculateTopPadding())) {
            if (view.conflict)
                Banner(
                    "File changed on disk",
                    "Your edits are kept. Reload the current version before saving again.",
                    Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                    tone = Tone.WARNING,
                    actionLabel = "Reload",
                    onAction = { store.filesCommand(FilesCommand(reload = Step())) },
                )
            if (view.document_error.isNotEmpty())
                Banner(
                    "Unable to open file",
                    view.document_error,
                    Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                    tone = Tone.DANGER,
                )
            when {
                document == null ->
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Spinner(Modifier.size(26.dp))
                    }
                document.binary ->
                    EmptyState(
                        Glyph.FILE_PLAIN,
                        document.name,
                        "${document.mime_type.ifEmpty { "Binary file" }} · ${formatBytes(document.size)}",
                        Modifier.padding(top = 60.dp),
                    ) {
                        DButton(
                            "Open preview",
                            {
                                previewAttachment(
                                    com.dbpprt.dieter.core.composition.Attachments.part(
                                        document.name,
                                        document.mime_type,
                                        FilePaths.bytes(document),
                                    )
                                )
                            },
                            glyph = Glyph.EYE,
                        )
                    }
                markdown && isMarkdown ->
                    Column(
                        Modifier.fillMaxSize()
                            .verticalScroll(rememberScrollState())
                            .padding(horizontal = 20.dp, vertical = 12.dp)
                            .padding(bottom = padding.calculateBottomPadding())
                    ) {
                        RichText(text)
                    }
                else ->
                    BasicTextField(
                        text,
                        { store.editFileBuffer(view.document_key, document.content, it) },
                        Modifier.fillMaxSize()
                            .verticalScroll(rememberScrollState())
                            .padding(horizontal = 16.dp, vertical = 12.dp)
                            .padding(bottom = padding.calculateBottomPadding())
                            .testTag("file-editor")
                            .semantics { contentDescription = "File contents" },
                        textStyle = type.mono.copy(color = palette.label),
                        cursorBrush = SolidColor(if (apple) palette.info else colors.primary),
                    )
            }
        }
    }
    if (deleting)
        ConfirmDialog(
            "Delete ${route.path.substringAfterLast('/')}?",
            "This deletes the file from the workspace.",
            "Delete",
            {
                store.filesCommand(FilesCommand(delete = FilesDelete(route.path, false)))
                deleting = false
                store.pop()
            },
            { deleting = false },
            destructive = true,
        )
    if (moving)
        PromptDialog(
            "Rename or move",
            route.path,
            "Move",
            { destination ->
                if (FilePaths.normalize(destination).isSuccess) {
                    store.filesCommand(FilesCommand(move = FilesMove(route.path, destination)))
                    store.pop()
                }
                moving = false
            },
            { moving = false },
        )
}

// ---------------------------------------------------------------------------------------------
// Machines
// ---------------------------------------------------------------------------------------------

internal fun machineGlyph(platform: String): Glyph =
    when {
        platform.contains("linux", true) -> Glyph.SERVER
        else -> Glyph.MACHINE
    }

@Composable
internal fun MachinesScreen(store: MobileStore) {
    val session by store.session.collectAsState()
    val online = session.machines.count { it.online }
    Screen(
        ScreenChrome(
            "Machines",
            subtitle =
                if (session.machines.isEmpty()) ""
                else "$online of ${session.machines.size} online",
            actions =
                listOf(
                    ChromeAction("reconnect", "Reconnect", Glyph.REFRESH, onClick = store::retry)
                ),
        )
    ) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("machines-list"),
            state = listState,
            contentPadding = padding,
        ) {
            item { ConnectionNotice(store) }
            item { Spacer(Modifier.height(8.dp)) }
            if (session.machines.isEmpty())
                item {
                    EmptyState(
                        Glyph.MACHINE,
                        "No machines",
                        "Enroll a computer with the Dieter daemon to run agents on it.",
                        Modifier.padding(top = 40.dp),
                    )
                }
            itemsIndexed(session.machines, key = { _, machine -> machine.id }) { index, machine ->
                ListRow(
                    machine.display_name,
                    Modifier.testTag("machine-${machine.id}"),
                    position = Position.of(index, session.machines.size),
                    subtitle =
                        listOf(machine.presence, machine.detail)
                            .filter { it.isNotBlank() }
                            .distinct()
                            .joinToString(" · "),
                    glyph = machineGlyph(machine.platform),
                    tile = if (machine.online) Color(0xFF0A84FF) else Color(0xFF8E8E93),
                    accessory = Accessory.CHEVRON,
                    trailing = {
                        Box(
                            Modifier.size(9.dp)
                                .background(
                                    if (machine.online) palette.success else palette.tertiaryLabel,
                                    CircleShape,
                                )
                        )
                    },
                    onClick = { store.push(MobileRoute.Machine(machine.id)) },
                )
            }
        }
    }
}

@Composable
internal fun MachineScreen(store: MobileStore, machineId: String) {
    val session by store.session.collectAsState()
    val telemetry by store.telemetry.collectAsState()
    var operation by remember { mutableStateOf<MachineOperationState?>(null) }
    var rename by remember { mutableStateOf(false) }
    val machine = session.machines.firstOrNull { it.id == machineId }
    val readings = telemetry.machines[machineId]
    val information = readings?.information
    Screen(
        ScreenChrome(
            machine?.display_name ?: "Machine",
            subtitle = machine?.presence.orEmpty(),
            actions =
                listOf(ChromeAction("rename-machine", "Rename", Glyph.RENAME) { rename = true }),
        )
    ) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("machine-detail"),
            state = listState,
            contentPadding = padding,
        ) {
            if (machine == null) {
                item { Placeholder("This machine is no longer enrolled.") }
                return@LazyColumn
            }
            item {
                SectionHeader("Connection")
                Group(
                    listOfNotNull(
                        "Status" to
                            machine.presence.ifEmpty {
                                if (machine.online) "Online" else "Offline"
                            },
                        machine.route.takeIf { it.isNotEmpty() }?.let { "Route" to it },
                        "Dieter" to machine.release_version,
                        machine.privacy_label
                            .takeIf { it.isNotEmpty() }
                            ?.let {
                                val state =
                                    when {
                                        machine.privacy_warning -> "Degraded"
                                        machine.privacy_active -> "On"
                                        else -> "Off"
                                    }
                                "Privacy mode" to
                                    if (machine.privacy_stale) "$state (last known)" else state
                            },
                        machine.sync_label.takeIf { it.isNotEmpty() }?.let { "Sync" to it },
                    )
                ) { (title, value), position ->
                    ListRow(title, position = position, value = value)
                }
                // The shared wording explains what an active or degraded privacy mode means.
                if (machine.privacy_active || machine.privacy_warning)
                    SectionFooter(machine.privacy_label)
            }
            if (information != null) {
                item {
                    SectionHeader("System")
                    Group(
                        listOfNotNull(
                            "System" to
                                listOf(information.os_name, information.os_version)
                                    .filter { it.isNotEmpty() }
                                    .joinToString(" "),
                            information.hardware_model
                                .takeIf { it.isNotEmpty() }
                                ?.let { "Model" to it },
                            information.processor
                                .takeIf { it.isNotEmpty() }
                                ?.let { "Processor" to it },
                            "Cores" to "${information.logical_cpu_count}",
                            "Active agents" to "${information.active_agent_count}",
                        )
                    ) { (title, value), position ->
                        ListRow(title, position = position, value = value)
                    }
                }
                item {
                    SectionHeader("Load")
                    Column(
                        Modifier.fillMaxWidth()
                            .padding(horizontal = ScreenMargin)
                            .clip(groupShape(Position.SINGLE))
                            .background(palette.cell)
                            .padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(14.dp),
                    ) {
                        Gauge(
                            "CPU",
                            "${information.cpu_usage_percent.toInt()}%",
                            (information.cpu_usage_percent / 100).toFloat(),
                        )
                        if (information.memory_total_bytes > 0)
                            Gauge(
                                "Memory",
                                "${gigabytes(information.memory_used_bytes)} of ${gigabytes(information.memory_total_bytes)} GB",
                                information.memory_used_bytes.toFloat() /
                                    information.memory_total_bytes,
                            )
                        Row {
                            Text(
                                "Free storage",
                                Modifier.weight(1f),
                                style = type.subheadline,
                                color = palette.secondaryLabel,
                            )
                            Text(
                                "${gigabytes(information.disk_free_bytes)} GB",
                                style = type.subheadline,
                                color = palette.label,
                            )
                        }
                        Row {
                            Text(
                                "Network",
                                Modifier.weight(1f),
                                style = type.subheadline,
                                color = palette.secondaryLabel,
                            )
                            Text(
                                "↓ ${formatBytes(information.network_receive_bytes_per_second.toLong())}/s  ↑ ${formatBytes(information.network_send_bytes_per_second.toLong())}/s",
                                style = type.subheadline,
                                color = palette.label,
                            )
                        }
                    }
                }
            }
            readings
                ?.operations
                ?.takeIf { it.isNotEmpty() }
                ?.let { operations ->
                    item {
                        SectionHeader("Actions")
                        Group(operations) { state, position ->
                            val copy =
                                com.dbpprt.dieter.core.client.rules.MachineExports.operationCopy(
                                    state.action.value
                                )
                            ListRow(
                                copy.menu_title,
                                position = position,
                                subtitle =
                                    state.unavailable_reason.takeIf {
                                        !state.available && it.isNotEmpty()
                                    },
                                destructive = copy.destructive,
                                enabled = state.available && !telemetry.operation_pending,
                                onClick = { operation = state },
                            )
                        }
                        if (telemetry.operation_result.isNotEmpty())
                            SectionFooter(telemetry.operation_result)
                    }
                }
            if (readings?.loading == true && information == null)
                item {
                    Box(
                        Modifier.fillMaxWidth().padding(32.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Spinner(Modifier.size(24.dp))
                    }
                }
            readings
                ?.error
                ?.takeIf { it.isNotEmpty() }
                ?.let { failure ->
                    item {
                        Banner(
                            "Telemetry unavailable",
                            failure,
                            Modifier.padding(horizontal = ScreenMargin, vertical = 12.dp),
                            tone = Tone.WARNING,
                            actionLabel = "Retry",
                            onAction = {
                                store.command(
                                    Command(
                                        telemetry =
                                            TelemetryCommand(
                                                select = TelemetrySelect(machineId, true)
                                            )
                                    )
                                )
                            },
                        )
                    }
                }
            val processes = information?.processes.orEmpty().take(30)
            if (processes.isNotEmpty()) {
                item { SectionHeader("Top processes") }
                itemsIndexed(processes, key = { _, process -> process.pid }) { index, process ->
                    ListRow(
                        process.name,
                        position = Position.of(index, processes.size),
                        value = "PID ${process.pid}",
                    )
                }
            }
        }
    }
    operation?.let { state ->
        val copy =
            com.dbpprt.dieter.core.client.rules.MachineExports.operationCopy(state.action.value)
        ConfirmDialog(
            copy.title,
            copy.explanation,
            copy.button,
            {
                store.command(
                    Command(
                        telemetry = TelemetryCommand(perform = TelemetryOperation(state.action))
                    )
                )
                operation = null
            },
            { operation = null },
            destructive = copy.destructive,
        )
    }
    if (rename && machine != null)
        PromptDialog(
            "Rename machine",
            machine.display_name,
            "Save",
            {
                store.command(Command(rename_machine = RenameMachine(machineId, it)))
                rename = false
            },
            { rename = false },
            placeholder = "Machine name",
        )
}

private fun gigabytes(bytes: Long) =
    ((bytes / 107_374_182.4).toInt() / 10.0).let {
        if (it >= 100) it.toInt().toString() else it.toString()
    }

@Composable
private fun Gauge(title: String, value: String, fraction: Float) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row {
            Text(
                title,
                Modifier.weight(1f),
                style = type.subheadline,
                color = palette.secondaryLabel,
            )
            Text(
                value,
                style = type.subheadline.copy(fontWeight = FontWeight.SemiBold),
                color = palette.label,
            )
        }
        ProgressBar(fraction, color = if (fraction > .85f) palette.warning else palette.info)
    }
}

// ---------------------------------------------------------------------------------------------
// Usage
// ---------------------------------------------------------------------------------------------

@Composable
internal fun UsageScreen(store: MobileStore) {
    val view by store.quotas.collectAsState()
    var reset by remember { mutableStateOf<QuotaAccountRow?>(null) }
    Screen(
        ScreenChrome(
            "Usage",
            subtitle = "Provider accounts",
            actions =
                listOf(
                    ChromeAction("refresh-usage", "Refresh", Glyph.REFRESH) {
                        store.command(Command(quotas = QuotasCommand(load = QuotasLoad(true))))
                    }
                ),
        )
    ) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("usage"),
            state = listState,
            contentPadding = padding,
        ) {
            if (view.error.isNotEmpty())
                item {
                    Banner(
                        "Usage unavailable",
                        view.error,
                        Modifier.padding(horizontal = ScreenMargin, vertical = 8.dp),
                        tone = Tone.WARNING,
                        actionLabel = "Retry",
                        onAction = {
                            store.command(Command(quotas = QuotasCommand(load = QuotasLoad())))
                        },
                    )
                }
            if (view.loading && view.group_rows.isEmpty())
                item {
                    Box(
                        Modifier.fillMaxWidth().padding(40.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Spinner(Modifier.size(24.dp))
                    }
                }
            view.group_rows.forEach { group ->
                item("group-${group.provider}") {
                    SectionHeader(
                        group.provider_name,
                        prominent = true,
                        trailing = {
                            Text(
                                group.summary,
                                style = type.footnote,
                                color = palette.secondaryLabel,
                            )
                        },
                    )
                }
                itemsIndexed(
                    group.accounts,
                    key = { _, account -> "${group.provider}-${account.account_key}" },
                ) { _, account ->
                    ContentCard(Modifier.padding(horizontal = ScreenMargin, vertical = 5.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(
                                    account.identity.ifEmpty { account.label },
                                    style = type.headline,
                                    color = palette.label,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                if (account.subtitle.isNotEmpty())
                                    Text(
                                        account.subtitle,
                                        style = type.footnote,
                                        color = palette.secondaryLabel,
                                    )
                            }
                            if (account.remaining >= 0)
                                Text(
                                    "${account.remaining}%",
                                    style = type.title2,
                                    color =
                                        if (account.remaining < 20)
                                            palette.warning.readableOn(palette.cell)
                                        else palette.label,
                                )
                        }
                        if (account.remaining >= 0) {
                            Spacer(Modifier.height(10.dp))
                            ProgressBar(
                                account.remaining / 100f,
                                color =
                                    if (account.remaining < 20) palette.warning
                                    else palette.success,
                            )
                        }
                        account.status
                            .ifEmpty { account.unavailable }
                            .takeIf { it.isNotEmpty() }
                            ?.let {
                                Spacer(Modifier.height(8.dp))
                                Text(it, style = type.footnote, color = palette.secondaryLabel)
                            }
                        if (account.windows.isNotEmpty()) {
                            Spacer(Modifier.height(10.dp))
                            account.windows.forEach { window ->
                                Row(Modifier.padding(vertical = 3.dp)) {
                                    Text(
                                        window.name,
                                        Modifier.weight(1f),
                                        style = type.subheadline,
                                        color = palette.label,
                                    )
                                    Text(
                                        listOfNotNull(
                                                if (window.remaining >= 0)
                                                    "${window.remaining}% left"
                                                else "Not reported",
                                                window.resets_at
                                                    .takeIf { it.isNotEmpty() }
                                                    ?.let { "resets $it" },
                                            )
                                            .joinToString(" · "),
                                        style = type.subheadline,
                                        color = palette.secondaryLabel,
                                    )
                                }
                            }
                        }
                        account.details
                            .filter { !it.monetary }
                            .forEach {
                                Text(
                                    "${it.label} · ${it.text}",
                                    style = type.footnote,
                                    color = palette.secondaryLabel,
                                )
                            }
                        account.machines.forEach {
                            Text(
                                "${it.name} · ${it.state}",
                                style = type.footnote,
                                color = palette.secondaryLabel,
                            )
                        }
                        Spacer(Modifier.height(8.dp))
                        Hairline()
                        Row(
                            Modifier.padding(top = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                "Include in summary",
                                Modifier.weight(1f),
                                style = type.subheadline,
                                color = palette.label,
                            )
                            DSwitch(
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
                        if (account.can_reset)
                            DButton(
                                "Use reset credit…",
                                { reset = account },
                                Modifier.padding(top = 8.dp),
                                kind = ButtonKind.TONAL,
                                enabled = account.account_key !in view.mutating,
                            )
                    }
                }
            }
            if (!view.loading && view.group_rows.isEmpty() && view.error.isEmpty())
                item {
                    EmptyState(
                        Glyph.USAGE,
                        "No provider usage",
                        "Accounts report usage through an enrolled machine.",
                        Modifier.padding(top = 40.dp),
                    )
                }
        }
    }
    reset?.let { account ->
        ConfirmDialog(
            "Use a reset credit?",
            "This spends one reset credit for ${account.identity}.",
            "Use credit",
            {
                store.command(
                    Command(
                        quotas = QuotasCommand(consume_reset = QuotaAccount(account.account_key))
                    )
                )
                reset = null
            },
            { reset = null },
        )
    }
}

// ---------------------------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------------------------

@Composable
internal fun SettingsScreen(store: MobileStore) {
    val session by store.session.collectAsState()
    val selectedPalette by store.palette.collectAsState()
    val appearance by store.appearance.collectAsState()
    val dynamic by store.dynamicColor.collectAsState()
    val outbox by store.outbox.collectAsState()
    var signOut by remember { mutableStateOf(false) }
    var gatewayEditor by remember { mutableStateOf<GatewayEntry?>(null) }
    var addGateway by remember { mutableStateOf(false) }
    var removingGateway by remember { mutableStateOf<GatewayEntry?>(null) }
    Screen(ScreenChrome("Settings")) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("settings"),
            state = listState,
            contentPadding = padding,
        ) {
            item("appearance") {
                SectionHeader("Appearance")
                Column(
                    Modifier.fillMaxWidth()
                        .padding(horizontal = ScreenMargin)
                        .clip(groupShape(Position.SINGLE))
                        .background(palette.cell)
                        .padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    val modes = listOf("system" to "System", "light" to "Light", "dark" to "Dark")
                    Segmented(
                        modes.map { it.second },
                        modes.indexOfFirst { it.first == appearance }.coerceAtLeast(0),
                        { store.setAppearance(modes[it].first) },
                        testTagPrefix = "appearance",
                    )
                    if (!apple && platformSupportsDynamicColor)
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text("Dynamic color", style = type.body, color = palette.label)
                                Text(
                                    "Use colors from your wallpaper",
                                    style = type.footnote,
                                    color = palette.secondaryLabel,
                                )
                            }
                            DSwitch(dynamic, store::setDynamicColor)
                        }
                    if (apple || !dynamic)
                        FlowRow(
                            Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                            maxItemsInEachRow = 4,
                        ) {
                            DieterPalette.entries.forEach { item ->
                                PaletteSwatch(item, item == selectedPalette, Modifier.weight(1f)) {
                                    store.setPalette(item)
                                }
                            }
                        }
                }
            }
            item("conversation") {
                SectionHeader("Conversations")
                ListRow(
                    "Show reasoning",
                    position = Position.SINGLE,
                    subtitle = "Display the agent’s thinking between replies",
                    glyph = Glyph.BRAIN,
                    tile = Color(0xFFAF52DE),
                    trailing = {
                        DSwitch(
                            session.show_reasoning,
                            { store.command(Command(set_show_reasoning = SetShowReasoning(it))) },
                        )
                    },
                )
            }
            item("connection") {
                SectionHeader("Connection")
                val disconnected = session.phase == SessionSlice.Phase.PHASE_DISCONNECTED
                Group(listOfNotNull(0, 1, if (disconnected) null else 2)) { index, position ->
                    when (index) {
                        0 ->
                            ListRow(
                                session.phase_label.ifEmpty { "Status" },
                                position = position,
                                subtitle = session.gateway_origin,
                                glyph = Glyph.GLOBE,
                                tile =
                                    if (session.phase == SessionSlice.Phase.PHASE_CONNECTED)
                                        Color(0xFF30B158)
                                    else Color(0xFFFF9F0A),
                                subtitleMaxLines = 1,
                            )
                        1 ->
                            ListRow(
                                if (disconnected) "Connect" else "Reconnect",
                                position = position,
                                glyph = Glyph.SYNC,
                                onClick = {
                                    if (disconnected)
                                        store.command(Command(set_connected = SetConnected(true)))
                                    else store.retry()
                                },
                            )
                        else ->
                            ListRow(
                                "Disconnect",
                                position = position,
                                glyph = Glyph.OFFLINE,
                                destructive = true,
                                onClick = {
                                    store.command(Command(set_connected = SetConnected(false)))
                                },
                            )
                    }
                }
                if (session.error.isNotEmpty()) SectionFooter(session.error)
            }
            item("gateways") {
                SectionHeader("Gateways")
                val gateways = session.gateways
                Group(gateways + listOf<GatewayEntry?>(null)) { gateway, position ->
                    if (gateway == null)
                        ListRow(
                            "Add gateway…",
                            position = position,
                            glyph = Glyph.ADD,
                            onClick = { addGateway = true },
                        )
                    else {
                        val menu = rememberMenuState()
                        MenuAnchor(menu) {
                            ListRow(
                                gateway.name.ifEmpty { gateway.origin },
                                position = position,
                                subtitle = gateway.origin.takeIf { gateway.name.isNotEmpty() },
                                accessory = if (gateway.active) Accessory.CHECK else Accessory.NONE,
                                onClick = {
                                    if (!gateway.active)
                                        store.command(
                                            Command(select_gateway = SelectGateway(gateway.origin))
                                        )
                                },
                                onLongClick = {
                                    menu.show(
                                        listOf(
                                            MenuSection(
                                                listOf(
                                                    ChromeAction(
                                                        "edit-gateway",
                                                        "Edit…",
                                                        Glyph.EDIT,
                                                    ) {
                                                        gatewayEditor = gateway
                                                    },
                                                    ChromeAction(
                                                        "remove-gateway",
                                                        "Remove",
                                                        Glyph.TRASH,
                                                        destructive = true,
                                                        enabled = gateways.size > 1,
                                                    ) {
                                                        removingGateway = gateway
                                                    },
                                                )
                                            )
                                        )
                                    )
                                },
                            )
                        }
                    }
                }
            }
            if (outbox.machines.isNotEmpty() || outbox.failed_operations.isNotEmpty())
                item("pending") {
                    SectionHeader("Pending changes")
                    val machines = outbox.machines
                    Group(machines) { machine, position ->
                        ListRow(
                            machine.title,
                            position = position,
                            subtitle = machine.detail,
                            glyph = Glyph.SYNC,
                            trailing =
                                if (machine.retry_title.isNotEmpty())
                                    ({
                                        DButton(
                                            machine.retry_title,
                                            {
                                                store.command(
                                                    Command(
                                                        retry_pending =
                                                            RetryPending(
                                                                daemon_id = machine.daemon_id
                                                            )
                                                    )
                                                )
                                            },
                                            kind = ButtonKind.PLAIN,
                                        )
                                    })
                                else null,
                        )
                    }
                    if (outbox.failed_operations.isNotEmpty()) Spacer(Modifier.height(12.dp))
                    Group(outbox.failed_operations) { failure, position ->
                        ListRow(
                            failure.label,
                            position = position,
                            subtitle = failure.failure,
                            glyph = Glyph.ERROR,
                            glyphTint = palette.destructive,
                            trailing = {
                                Row {
                                    DButton(
                                        "Retry",
                                        {
                                            store.command(
                                                Command(retry_pending = RetryPending(failure.id))
                                            )
                                        },
                                        kind = ButtonKind.PLAIN,
                                    )
                                    DButton(
                                        "Discard",
                                        {
                                            store.command(
                                                Command(
                                                    discard_pending = DiscardPending(failure.id)
                                                )
                                            )
                                        },
                                        kind = ButtonKind.PLAIN,
                                    )
                                }
                            },
                        )
                    }
                }
            item("account") {
                SectionHeader("Account")
                ListRow(
                    "Sign out",
                    Modifier.testTag("sign-out"),
                    position = Position.SINGLE,
                    destructive = true,
                    glyph = Glyph.SIGN_OUT,
                    onClick = { signOut = true },
                )
                SectionFooter(
                    "Signing out clears this device’s cached workspace, unsent work and drafts."
                )
            }
        }
    }
    if (addGateway || gatewayEditor != null)
        GatewayEditor(store, gatewayEditor) {
            addGateway = false
            gatewayEditor = null
        }
    removingGateway?.let { gateway ->
        ConfirmDialog(
            "Remove gateway?",
            gateway.origin,
            "Remove",
            {
                store.command(Command(remove_gateway = RemoveGateway(gateway.origin)))
                removingGateway = null
            },
            { removingGateway = null },
            destructive = true,
        )
    }
    if (signOut)
        ConfirmDialog(
            "Sign out of Dieter?",
            "This clears this device’s cached workspace, unsent work and drafts for this account.",
            "Sign out",
            {
                store.command(Command(sign_out = SignOut()))
                signOut = false
            },
            { signOut = false },
            destructive = true,
        )
}

@Composable
private fun PaletteSwatch(
    item: DieterPalette,
    selected: Boolean,
    modifier: Modifier,
    onClick: () -> Unit,
) {
    val tokens = item.tokens
    Column(
        modifier
            .clip(RoundedCornerShape(14.dp))
            .pressable(onClick = onClick)
            .padding(vertical = 4.dp)
            .testTag("palette-${item.slug}"),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            Modifier.size(48.dp)
                .clip(CircleShape)
                .border(
                    if (selected) 2.5.dp else 0.dp,
                    if (selected) palette.label else Color.Transparent,
                    CircleShape,
                )
                .padding(if (selected) 4.dp else 0.dp)
                .clip(CircleShape)
                .background(
                    androidx.compose.ui.graphics.Brush.linearGradient(
                        listOf(Color(tokens.shellStart), Color(tokens.shellEnd))
                    )
                )
        )
        Spacer(Modifier.height(6.dp))
        Text(
            item.displayName.substringBefore(' '),
            style = type.caption,
            color = if (selected) palette.label else palette.secondaryLabel,
            maxLines = 1,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun GatewayEditor(store: MobileStore, gateway: GatewayEntry?, onDismiss: () -> Unit) {
    var name by remember { mutableStateOf(gateway?.name.orEmpty()) }
    var url by remember { mutableStateOf(gateway?.origin ?: "https://") }
    Sheet(
        if (gateway == null) "Add Gateway" else "Edit Gateway",
        onDismiss,
        size = SheetSize.MEDIUM,
        confirm =
            ChromeAction("save-gateway", "Save", Glyph.CHECK, enabled = url.length > 8) {
                store.action {
                    store.core.dispatch(Command(use_gateway = UseGateway(url, name)))
                    onDismiss()
                }
            },
    ) {
        Column(
            Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            MobileTextField(
                name,
                { name = it },
                Modifier.fillMaxWidth(),
                label = { Text("Name") },
                placeholder = { Text("Name") },
                singleLine = true,
            )
            MobileTextField(
                url,
                { url = it },
                Modifier.fillMaxWidth(),
                label = { Text("Gateway URL") },
                placeholder = { Text("https://") },
                singleLine = true,
            )
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Screens
// ---------------------------------------------------------------------------------------------

@Composable
internal fun ScreensScreen(store: MobileStore) {
    val session by store.session.collectAsState()
    Screen(ScreenChrome("Screens", subtitle = "View and control a machine’s display")) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("screens-list"),
            state = listState,
            contentPadding = padding,
        ) {
            item { Spacer(Modifier.height(8.dp)) }
            if (session.machines.isEmpty())
                item {
                    EmptyState(
                        Glyph.SCREENS,
                        "No machines",
                        "Enrolled machines that share their screen appear here.",
                        Modifier.padding(top = 40.dp),
                    )
                }
            itemsIndexed(session.machines, key = { _, machine -> machine.id }) { index, machine ->
                ListRow(
                    machine.display_name,
                    Modifier.testTag("screen-${machine.id}"),
                    position = Position.of(index, session.machines.size),
                    subtitle = machine.screen_status.ifEmpty { machine.remote_desktop_reason },
                    glyph = Glyph.SCREENS,
                    tile = if (machine.can_share_screen) Color(0xFF5E5CE6) else Color(0xFF8E8E93),
                    accessory = Accessory.CHEVRON,
                    enabled = machine.can_share_screen,
                    onClick = { store.push(MobileRoute.ScreenSession(machine.id)) },
                )
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Terminals
// ---------------------------------------------------------------------------------------------

@Composable
internal fun TerminalsScreen(store: MobileStore, inConversation: Boolean = false) {
    val view by store.terminals.collectAsState()
    val local by store.cardTerminals.collectAsState()
    val conversation by store.conversation.collectAsState()
    var create by remember { mutableStateOf(false) }
    val cardId = if (inConversation) store.selectedCard.value else ""
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
    Screen(
        ScreenChrome(
            "Terminals",
            subtitle = if (inConversation) conversation.card?.title.orEmpty() else view.status,
            actions =
                listOf(ChromeAction("new-terminal", "New terminal", Glyph.ADD) { create = true }),
        )
    ) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("terminals-list"),
            state = listState,
            contentPadding = padding,
        ) {
            if (local.error.isNotEmpty() && inConversation)
                item {
                    Banner(
                        "Terminals unavailable",
                        local.error,
                        Modifier.padding(horizontal = ScreenMargin, vertical = 8.dp),
                        tone = Tone.DANGER,
                    )
                }
            item { Spacer(Modifier.height(8.dp)) }
            if (entries.isEmpty())
                item {
                    EmptyState(
                        Glyph.TERMINAL,
                        "No terminals",
                        "Persistent shells keep running on the machine when this app disconnects.",
                        Modifier.padding(top = 40.dp),
                    ) {
                        DButton("New terminal", { create = true }, glyph = Glyph.ADD)
                    }
                }
            itemsIndexed(entries, key = { _, entry -> entry.id }) { index, entry ->
                ListRow(
                    entry.terminal?.name.orEmpty().ifEmpty { "Terminal" },
                    Modifier.testTag("terminal-${entry.id}"),
                    position = Position.of(index, entries.size),
                    subtitle =
                        listOf(entry.machine_name, entry.row?.status.orEmpty())
                            .filter { it.isNotBlank() }
                            .joinToString(" · "),
                    glyph = Glyph.TERMINAL,
                    tile = Color(0xFF3A3A3C),
                    accessory = Accessory.CHEVRON,
                    onClick = { store.push(MobileRoute.TerminalSession(entry.id, cardId)) },
                )
            }
        }
    }
    if (create && !inConversation) TerminalEditor(store) { create = false }
    if (create && inConversation)
        PromptDialog(
            "New terminal",
            "",
            "Create",
            { name ->
                store.command(
                    Command(
                        terminals =
                            TerminalsCommand(
                                scope = MobileStore.TERMINAL_SCOPE,
                                create = CreateTerminal(name = name),
                            )
                    )
                )
                create = false
            },
            { create = false },
            placeholder = "Terminal name",
        )
}

@Composable
internal fun TerminalSessionScreen(store: MobileStore, terminalId: String, cardId: String) {
    val view by store.terminals.collectAsState()
    val local by store.cardTerminals.collectAsState()
    val selected by store.visibleTerminal.collectAsState()
    val acceptsInput by store.terminalAcceptsInput.collectAsState()
    var rename by remember { mutableStateOf(false) }
    var closing by remember { mutableStateOf(false) }
    val entry =
        if (cardId.isNotEmpty())
            local.terminals
                .firstOrNull { it.id == terminalId }
                ?.let {
                    OverviewTerminal(
                        id = it.id,
                        terminal = it,
                        row = local.rows.firstOrNull { row -> row.id == it.id },
                    )
                }
        else view.entries.firstOrNull { it.id == terminalId }
    fun send(value: TerminalsCommand) =
        store.command(Command(terminals = value.copy(scope = MobileStore.TERMINAL_SCOPE)))
    DisposableEffect(store) {
        send(TerminalsCommand(active = Toggle(true)))
        onDispose { send(TerminalsCommand(active = Toggle(false))) }
    }
    Screen(
        ScreenChrome(
            entry?.terminal?.name.orEmpty().ifEmpty { "Terminal" },
            subtitle =
                listOf(entry?.machine_name.orEmpty(), entry?.row?.status.orEmpty())
                    .filter { it.isNotBlank() }
                    .joinToString(" · "),
            actions =
                listOf(
                    ChromeAction(
                        "terminal-menu",
                        "Terminal actions",
                        Glyph.MORE_HORIZONTAL,
                        menu =
                            listOf(
                                MenuSection(
                                    listOf(
                                        ChromeAction("rename-terminal", "Rename…", Glyph.RENAME) {
                                            rename = true
                                        },
                                        ChromeAction(
                                            "close-terminal",
                                            "Close terminal",
                                            Glyph.TRASH,
                                            destructive = true,
                                        ) {
                                            closing = true
                                        },
                                    )
                                )
                            ),
                    )
                ),
        )
    ) {
        Column(
            Modifier.fillMaxSize()
                .background(Color(0xFF0A0A0A))
                .padding(top = padding.calculateTopPadding())
                .imePadding()
        ) {
            if (selected == terminalId)
                NativeTerminal(store, Modifier.weight(1f).fillMaxWidth().testTag("terminal-view"))
            else
                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    Spinner(Modifier.size(24.dp), color = Color.White)
                }
            TerminalKeys(
                store,
                acceptsInput,
                Modifier.padding(
                    bottom =
                        if (
                            (WindowInsets.ime.getBottom(
                                androidx.compose.ui.platform.LocalDensity.current
                            ) > 0)
                        )
                            4.dp
                        else padding.calculateBottomPadding()
                ),
            )
        }
    }
    if (rename)
        PromptDialog(
            "Rename terminal",
            entry?.terminal?.name.orEmpty(),
            "Save",
            {
                send(TerminalsCommand(rename = TerminalRename(terminalId, it)))
                rename = false
            },
            { rename = false },
        )
    if (closing)
        ConfirmDialog(
            "Close terminal?",
            entry?.row?.close_message?.ifEmpty { null }
                ?: "This ends the shell and clears its scrollback.",
            "Close",
            {
                send(TerminalsCommand(close = TerminalId(terminalId)))
                closing = false
                store.pop()
            },
            { closing = false },
            destructive = true,
        )
}

@Composable
private fun TerminalKeys(store: MobileStore, enabled: Boolean, modifier: Modifier = Modifier) {
    Row(
        modifier
            .fillMaxWidth()
            .background(Color(0xFF1C1C1E))
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 8.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        val keys =
            listOf(
                "esc" to { store.terminalKeys.tryEmit(TerminalKey.TERMINAL_KEY_ESCAPE) },
                "tab" to { store.terminalKeys.tryEmit(TerminalKey.TERMINAL_KEY_TAB) },
                "ctrl C" to
                    {
                        store.terminalInput(byteArrayOf(3))
                        true
                    },
                "↑" to { store.terminalKeys.tryEmit(TerminalKey.TERMINAL_KEY_UP) },
                "↓" to { store.terminalKeys.tryEmit(TerminalKey.TERMINAL_KEY_DOWN) },
                "←" to { store.terminalKeys.tryEmit(TerminalKey.TERMINAL_KEY_LEFT) },
                "→" to { store.terminalKeys.tryEmit(TerminalKey.TERMINAL_KEY_RIGHT) },
            )
        keys.forEach { (label, action) ->
            Box(
                Modifier.height(34.dp)
                    .widthIn(min = 44.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(Color(0xFF3A3A3C))
                    .pressable(enabled = enabled, onClick = { action() })
                    .padding(horizontal = 10.dp)
                    .semantics { contentDescription = "Send $label" },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    label,
                    style = type.footnote.copy(fontWeight = FontWeight.Medium),
                    color = if (enabled) Color.White else Color(0xFF8E8E93),
                )
            }
        }
    }
}
