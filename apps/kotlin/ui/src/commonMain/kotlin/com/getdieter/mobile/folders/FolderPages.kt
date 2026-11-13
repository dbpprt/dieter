package com.getdieter.mobile.folders

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
import androidx.compose.ui.unit.dp
import com.getdieter.api.v1.FolderDeleteGuard
import com.getdieter.client.v1.*
import com.getdieter.core.folders.FolderPresentation
import com.getdieter.core.folders.FolderSettings
import com.getdieter.core.folders.Folders
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.design.Tone
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.platform.rememberFolderLocationPicker
import com.getdieter.mobile.store.*

@Composable
internal fun FolderPageScreen(store: MobileStore, folderId: String, page: FolderSection) {
    when (page) {
        FolderSection.DEVICE -> OnThisDeviceScreen(store, folderId)
        FolderSection.TRASH -> TrashScreen(store, folderId)
        FolderSection.SETTINGS -> FolderSettingsScreen(store, folderId)
    }
}

/**
 * A folder on this device: its direction, what happens after an upload, where it lives, its
 * overrides of the device settings, its home machine, and removing it from this device.
 */
@Composable
private fun OnThisDeviceScreen(store: MobileStore, folderId: String) {
    val folder by store.folders.folder.collectAsState()
    val slice = folder.takeIf { it.id == folderId } ?: FolderSlice(id = folderId)
    val device = slice.device ?: FolderDeviceState()
    val local = device.settings ?: FolderLocalSettings(folder_id = folderId)
    val sync by store.folders.settings.collectAsState()
    var removing by remember { mutableStateOf(false) }
    var moving by remember { mutableStateOf<Pair<String, String>?>(null) }
    val picker =
        rememberFolderLocationPicker(
            onPicked = { location, label -> moving = location to label },
            onError = { store.error.value = it },
        )
    fun update(change: FolderLocalSettings.() -> FolderLocalSettings) =
        store.folders.setFolderSettings(local.change().copy(folder_id = folderId))
    Screen(ScreenChrome(FolderSection.DEVICE.title, subtitle = slice.name)) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("folder-device"),
            state = listState,
            contentPadding = padding,
        ) {
            if (!device.attached) {
                item("detached") {
                    EmptyState(
                        Glyph.PHONE,
                        "Not on this device",
                        "Keep this folder on this device to choose how it syncs here.",
                    )
                }
                return@LazyColumn
            }
            if (device.pending_label.isNotEmpty())
                item("pending") {
                    FolderNote(
                        device.pending_label +
                            if (local.remove_after_upload)
                                " waiting. Uploaded files leave this device once a machine confirms them."
                            else " waiting."
                    )
                }
            item("direction") {
                SectionHeader("Direction")
                SettingsCell {
                    Segmented(
                        folderDirections.map { it.shortLabel() },
                        folderDirections.indexOf(device.direction).coerceAtLeast(0),
                        { store.folders.setDirection(folderId, folderDirections[it]) },
                        testTagPrefix = "folder-direction",
                    )
                    Text(
                        device.direction.detail(),
                        style = type.footnote,
                        color = palette.secondaryLabel,
                    )
                }
            }
            if (device.direction == FolderDirection.FOLDER_DIRECTION_UPLOAD_ONLY)
                item("after-upload") {
                    SectionHeader("After upload")
                    ListRow(
                        "Remove from this device",
                        position = Position.SINGLE,
                        subtitle = "Inbox style: files are freed here once uploaded, never deleted",
                        trailing = {
                            DSwitch(
                                local.remove_after_upload,
                                { on -> update { copy(remove_after_upload = on) } },
                                Modifier.testTag("folder-remove-after-upload"),
                            )
                        },
                    )
                }
            item("location") {
                SectionHeader("Location")
                val shared = device.settings?.location?.startsWith("content://") == true
                val options =
                    listOfNotNull(
                        picker?.let { "shared" },
                        if (picker != null) "private" else null,
                    )
                if (picker == null)
                    ListRow(
                        device.location_label,
                        position = Position.SINGLE,
                        glyph = Glyph.FOLDER,
                        subtitle = "Visible in the Files app",
                    )
                else
                    Group(options) { option, position ->
                        if (option == "shared")
                            ListRow(
                                "Shared folder…",
                                Modifier.testTag("folder-location-shared"),
                                position = position,
                                subtitle =
                                    if (shared) device.location_label
                                    else "Choose a folder other apps can see",
                                glyph = Glyph.FOLDER_OPEN,
                                accessory = if (shared) Accessory.CHECK else Accessory.NONE,
                                onClick = { picker() },
                            )
                        else
                            ListRow(
                                "Private to Dieter",
                                Modifier.testTag("folder-location-private"),
                                position = position,
                                subtitle = "Only Dieter and the share sheet reach it",
                                glyph = Glyph.LOCK,
                                accessory = if (!shared) Accessory.CHECK else Accessory.NONE,
                                onClick = {
                                    if (shared)
                                        moving = Folders.DEFAULT_LOCATION to "Private to Dieter"
                                },
                            )
                    }
            }
            item("overrides") {
                SectionHeader("Overrides")
                val deviceDefault = "Use device setting"
                Group(listOf("interval", "network", "download")) { row, position ->
                    when (row) {
                        "interval" -> {
                            val choices =
                                listOf("0" to deviceDefault) +
                                    sync.interval_options
                                        .filter {
                                            it.background ==
                                                FolderBackgroundSync.FOLDER_BACKGROUND_SYNC_INTERVAL
                                        }
                                        .map { it.minutes.toString() to it.label }
                            PickerRow(
                                "Sync interval",
                                choices
                                    .firstOrNull { it.first == local.interval_minutes.toString() }
                                    ?.second ?: deviceDefault,
                                choices,
                                local.interval_minutes.toString(),
                                true,
                                position,
                                Glyph.CLOCK,
                                tag = "folder-override-interval",
                            ) {
                                update { copy(interval_minutes = it.toInt()) }
                            }
                        }
                        "network" -> {
                            val choices =
                                listOf(
                                    FolderNetworkPolicy.FOLDER_NETWORK_POLICY_UNSPECIFIED.name to
                                        deviceDefault
                                ) + folderNetworks.map { it.name to it.label() }
                            PickerRow(
                                "Network",
                                if (
                                    local.network ==
                                        FolderNetworkPolicy.FOLDER_NETWORK_POLICY_UNSPECIFIED
                                )
                                    deviceDefault
                                else local.network.label(),
                                choices,
                                local.network.name,
                                true,
                                position,
                                Glyph.GLOBE,
                                tag = "folder-override-network",
                            ) { name ->
                                update {
                                    copy(
                                        network =
                                            FolderNetworkPolicy.entries.firstOrNull {
                                                it.name == name
                                            }
                                                ?: FolderNetworkPolicy
                                                    .FOLDER_NETWORK_POLICY_UNSPECIFIED
                                    )
                                }
                            }
                        }
                        else -> {
                            val choices =
                                listOf("device" to deviceDefault) +
                                    sync.auto_download_options.map {
                                        it.amount.toString() to it.label
                                    }
                            val selected =
                                if (local.auto_download_override)
                                    local.auto_download_bytes.toString()
                                else "device"
                            PickerRow(
                                "Download automatically",
                                choices.firstOrNull { it.first == selected }?.second
                                    ?: deviceDefault,
                                choices,
                                selected,
                                true,
                                position,
                                Glyph.PULL,
                                tag = "folder-override-download",
                            ) { key ->
                                update {
                                    if (key == "device") copy(auto_download_override = false)
                                    else
                                        copy(
                                            auto_download_override = true,
                                            auto_download_bytes = key.toLong(),
                                        )
                                }
                            }
                        }
                    }
                }
            }
            item("home") {
                SectionHeader("Home machine")
                val options = device.home_options
                PickerRow(
                    "Home machine",
                    device.home_label.ifEmpty { "Auto" },
                    options.map {
                        it.daemon_id to
                            it.label +
                                if (!it.online && it.daemon_id.isNotEmpty()) " (offline)" else ""
                    },
                    options.firstOrNull { it.selected }?.daemon_id.orEmpty(),
                    options.isNotEmpty(),
                    Position.SINGLE,
                    Glyph.SERVER,
                    tag = "folder-home",
                ) {
                    update { copy(home_daemon_id = it) }
                }
                SectionFooter(
                    "Auto prefers a machine with a direct connection, then the most recently reachable one."
                )
            }
            item("remove") {
                Spacer(Modifier.height(16.dp))
                ListRow(
                    "Remove from this device…",
                    Modifier.testTag("folder-remove-device"),
                    position = Position.SINGLE,
                    destructive = true,
                    glyph = Glyph.TRASH,
                    onClick = { removing = true },
                )
                SectionFooter(
                    "Removing never deletes the folder. Choose to keep the files here or delete " +
                        "only this device's copy."
                )
            }
        }
    }
    if (removing)
        Sheet("Remove from this device", { removing = false }, size = SheetSize.MEDIUM) {
            Group(listOf(false, true)) { delete, position ->
                ListRow(
                    if (delete) "Delete local copy" else "Keep files",
                    Modifier.testTag(if (delete) "folder-remove-delete" else "folder-remove-keep"),
                    position = position,
                    subtitle =
                        if (delete) "Deletes this device's copy only; your machines keep the folder"
                        else "Stops syncing and leaves the files where they are",
                    destructive = delete,
                    glyph = if (delete) Glyph.TRASH else Glyph.FOLDER,
                    onClick = {
                        removing = false
                        store.folders.remove(folderId, delete)
                        store.pop()
                    },
                )
            }
        }
    moving?.let { (location, label) ->
        ConfirmDialog(
            "Move the folder to $label?",
            "The folder syncs into the new location from its machines. The old location keeps " +
                "its files.",
            "Move",
            {
                moving = null
                update { copy(location = location, location_label = label) }
            },
            { moving = null },
        )
    }
}

/** The daemons' trash: restore a deleted or replaced file, or delete it for good. */
@Composable
private fun TrashScreen(store: MobileStore, folderId: String) {
    val folder by store.folders.folder.collectAsState()
    val slice = folder.takeIf { it.id == folderId } ?: FolderSlice(id = folderId)
    val trash = slice.trash
    val daemons = slice.members.filter { it.daemon }
    var emptying by remember { mutableStateOf(false) }
    LaunchedEffect(folderId) { store.folders.loadTrash(folderId) }
    Screen(
        ScreenChrome(
            FolderSection.TRASH.title,
            subtitle = slice.name,
            actions =
                listOf(
                    ChromeAction(
                        "folder-trash-empty",
                        "Empty trash",
                        Glyph.TRASH,
                        enabled = trash?.rows?.isNotEmpty() == true,
                        destructive = true,
                    ) {
                        emptying = true
                    }
                ),
        )
    ) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("folder-trash"),
            state = listState,
            contentPadding = padding,
        ) {
            if (daemons.size > 1)
                item("machine") {
                    Spacer(Modifier.height(8.dp))
                    PickerRow(
                        "Machine",
                        trash?.daemon_name.orEmpty(),
                        daemons.map { it.member_id to it.name },
                        trash?.daemon_id.orEmpty(),
                        true,
                        Position.SINGLE,
                        Glyph.SERVER,
                        tag = "folder-trash-machine",
                    ) {
                        store.folders.loadTrash(folderId, it)
                    }
                }
            if (!trash?.error.isNullOrEmpty())
                item("error") {
                    Banner(
                        "Trash unavailable",
                        trash.error,
                        Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                        tone = Tone.WARNING,
                        actionLabel = "Retry",
                        onAction = { store.folders.loadTrash(folderId, trash.daemon_id) },
                    )
                }
            val rows = trash?.rows.orEmpty()
            if (rows.isEmpty() && trash?.loading != false && trash?.error.isNullOrEmpty())
                item("loading") {
                    Box(Modifier.fillMaxWidth().padding(32.dp), Alignment.Center) { Spinner() }
                }
            else if (rows.isEmpty())
                item("empty") {
                    EmptyState(
                        Glyph.TRASH,
                        "Nothing deleted recently",
                        "Machines keep deleted and replaced files for ${slice.trash_label.ifEmpty { "30 days" }.lowercase()}.",
                    )
                }
            else
                item("header") {
                    SectionHeader(
                        trash?.daemon_name?.let { "On $it" } ?: "Deleted files",
                        trailing = {
                            if (trash != null && trash.total_bytes > 0)
                                Text(
                                    FolderSettings.size(trash.total_bytes),
                                    style = type.footnote,
                                    color = palette.secondaryLabel,
                                )
                        },
                    )
                }
            itemsIndexed(rows, key = { _, row -> "trash-${row.id}" }) { index, row ->
                val menu = rememberMenuState()
                MenuAnchor(menu) {
                    ListRow(
                        row.name,
                        Modifier.testTag("folder-trash-${row.id}"),
                        position =
                            Position.of(
                                index,
                                rows.size + if (trash?.next.isNullOrEmpty()) 0 else 1,
                            ),
                        subtitle =
                            listOf(
                                    row.path.substringBeforeLast('/', ""),
                                    row.detail,
                                    row.size_label,
                                )
                                .filter { it.isNotBlank() }
                                .joinToString(" · "),
                        glyph = fileGlyph(row.name, false),
                        onLongClick = {
                            menu.show(
                                listOf(
                                    MenuSection(
                                        listOf(
                                            ChromeAction(
                                                "trash-purge",
                                                "Delete now",
                                                Glyph.TRASH,
                                                destructive = true,
                                            ) {
                                                store.folders.purge(
                                                    folderId,
                                                    trash?.daemon_id.orEmpty(),
                                                    listOf(row.id),
                                                )
                                            }
                                        )
                                    )
                                )
                            )
                        },
                        trailing = {
                            DButton(
                                "Restore",
                                {
                                    store.folders.restore(
                                        folderId,
                                        trash?.daemon_id.orEmpty(),
                                        listOf(row.id),
                                    )
                                },
                                Modifier.testTag("folder-trash-restore-${row.id}"),
                                kind = ButtonKind.PLAIN,
                            )
                        },
                    )
                }
            }
            if (!trash?.next.isNullOrEmpty())
                item("more") {
                    ListRow(
                        "Load more",
                        position = Position.LAST,
                        glyph = Glyph.ARROW_DOWN,
                        onClick = {
                            store.folders.loadTrash(folderId, trash.daemon_id, trash.next)
                        },
                    )
                }
        }
    }
    if (emptying)
        ConfirmDialog(
            "Empty the trash on ${trash?.daemon_name.orEmpty()}?",
            "Its deleted and replaced files are gone for good.",
            "Empty trash",
            {
                emptying = false
                store.folders.purge(folderId, trash?.daemon_id.orEmpty())
            },
            { emptying = false },
            destructive = true,
        )
}

/** The shared definition: name, rules, trash, deletion guard and linked project. */
@Composable
private fun FolderSettingsScreen(store: MobileStore, folderId: String) {
    val folder by store.folders.folder.collectAsState()
    val workspace by store.workspace.slice.collectAsState()
    val slice = folder.takeIf { it.id == folderId } ?: FolderSlice(id = folderId)
    var renaming by remember { mutableStateOf(false) }
    var editingRules by remember { mutableStateOf(false) }
    var archiving by remember { mutableStateOf(false) }
    Screen(ScreenChrome(FolderSection.SETTINGS.title, subtitle = slice.name)) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("folder-settings"),
            state = listState,
            contentPadding = padding,
        ) {
            if (slice.conflict_fields.isNotEmpty())
                item("conflicts") {
                    Banner(
                        "Edited on two devices at once",
                        slice.conflict_fields.joinToString(", ") +
                            ": save the value you want to keep.",
                        Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                        tone = Tone.WARNING,
                    )
                }
            item("name") {
                SectionHeader("Folder")
                ListRow(
                    "Name",
                    Modifier.testTag("folder-settings-name"),
                    position = Position.SINGLE,
                    value = slice.name,
                    accessory = Accessory.CHEVRON,
                    onClick = { renaming = true },
                )
            }
            item("rules") {
                SectionHeader("Ignore rules")
                val rules = slice.rules
                Group(rules.ifEmpty { listOf("") }.take(64) + "edit") { rule, position ->
                    if (rule == "edit")
                        ListRow(
                            "Edit rules…",
                            Modifier.testTag("folder-settings-rules"),
                            position = position,
                            glyph = Glyph.EDIT,
                            glyphTint = palette.accent,
                            onClick = { editingRules = true },
                        )
                    else
                        ListRow(
                            rule.ifEmpty { "No rules" },
                            position = position,
                            glyph = if (rule.startsWith("+")) Glyph.ADD else Glyph.EYE_SLASH,
                        )
                }
                SectionFooter(
                    "“-PATTERN” leaves matching files out, “+PATTERN” keeps them; the last match " +
                        "wins. .git and transfer files never sync."
                )
            }
            item("safety") {
                SectionHeader("Safety")
                Group(listOf("trash", "guard")) { row, position ->
                    if (row == "trash")
                        PickerRow(
                            "Keep deleted files",
                            slice.trash_label,
                            FolderSettings.TRASH_DAY_OPTIONS.map {
                                it.toString() to FolderPresentation.trashLabel(it)
                            },
                            FolderSettings.trashOption(slice.trash_days).toString(),
                            true,
                            position,
                            Glyph.TRASH,
                            tag = "folder-settings-trash",
                        ) {
                            store.folders.setTrashDays(folderId, it.toInt())
                        }
                    else {
                        val guards =
                            listOf(
                                FolderDeleteGuard.FOLDER_DELETE_GUARD_DEFAULT,
                                FolderDeleteGuard.FOLDER_DELETE_GUARD_STRICT,
                                FolderDeleteGuard.FOLDER_DELETE_GUARD_OFF,
                            )
                        PickerRow(
                            "Deletion guard",
                            slice.delete_guard_label,
                            guards.map { it.name to FolderPresentation.guardLabel(it) },
                            slice.delete_guard
                                .takeIf { it != FolderDeleteGuard.FOLDER_DELETE_GUARD_UNSPECIFIED }
                                ?.name ?: FolderDeleteGuard.FOLDER_DELETE_GUARD_DEFAULT.name,
                            true,
                            position,
                            Glyph.WARNING,
                            tag = "folder-settings-guard",
                        ) { name ->
                            guards
                                .firstOrNull { it.name == name }
                                ?.let {
                                    store.folders.setDeleteGuard(folderId, it)
                                }
                        }
                    }
                }
                SectionFooter(
                    "The deletion guard pauses a folder instead of applying a mass deletion until " +
                        "you apply or restore it."
                )
            }
            item("project") {
                SectionHeader("Agents")
                val projects = workspace.projects
                PickerRow(
                    "Linked project",
                    slice.project_name.ifEmpty { "None" },
                    listOf("" to "None") + projects.map { it.id to it.name },
                    slice.project_id,
                    true,
                    Position.SINGLE,
                    Glyph.PROJECTS,
                    tag = "folder-settings-project",
                ) {
                    store.folders.linkProject(folderId, it)
                }
                SectionFooter(
                    "Agents of a linked project learn where the folder is on the machines that " +
                        "keep it."
                )
            }
            item("archive") {
                Spacer(Modifier.height(16.dp))
                ListRow(
                    "Archive folder…",
                    Modifier.testTag("folder-settings-archive"),
                    position = Position.SINGLE,
                    destructive = true,
                    glyph = Glyph.ARCHIVE,
                    onClick = { archiving = true },
                )
            }
        }
    }
    if (renaming)
        PromptDialog(
            "Rename folder",
            slice.name,
            "Rename",
            {
                renaming = false
                store.folders.rename(folderId, it)
            },
            { renaming = false },
        )
    if (editingRules)
        RulesSheet(slice.rules, { store.folders.setRules(folderId, it) }) { editingRules = false }
    if (archiving)
        ConfirmDialog(
            "Archive ${slice.name}?",
            "Every member stops syncing it. Files stay where they are.",
            "Archive",
            {
                archiving = false
                store.folders.archive(folderId)
                store.pop()
            },
            { archiving = false },
            destructive = true,
        )
}

@Composable
private fun RulesSheet(rules: List<String>, save: (List<String>) -> Unit, dismiss: () -> Unit) {
    var text by remember { mutableStateOf(rules.joinToString("\n")) }
    Sheet(
        "Ignore rules",
        dismiss,
        confirm =
            ChromeAction("save-rules", "Save", Glyph.CHECK) {
                save(text.lines().map { it.trim() }.filter { it.isNotEmpty() })
                dismiss()
            },
    ) {
        FormColumn {
            MobileTextField(
                text,
                { text = it },
                Modifier.fillMaxWidth().heightIn(min = 180.dp).testTag("folder-rules-text"),
                label = { Text("One rule per line") },
                placeholder = { Text("-*.log") },
            )
        }
        SectionFooter("At most 64 rules.")
    }
}

/** A grouped cell holding a control and its caption. */
@Composable
internal fun SettingsCell(content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier.fillMaxWidth()
            .padding(horizontal = ScreenMargin)
            .clip(groupShape(Position.SINGLE))
            .background(palette.cell)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
        content = content,
    )
}
