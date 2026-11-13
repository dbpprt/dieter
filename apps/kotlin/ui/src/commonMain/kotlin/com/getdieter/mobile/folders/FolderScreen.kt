package com.getdieter.mobile.folders

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.getdieter.api.v1.FolderMode
import com.getdieter.api.v1.FolderState
import com.getdieter.client.v1.*
import com.getdieter.client.v1.Tone as SliceTone
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.platform.FolderFileRef
import com.getdieter.mobile.platform.rememberFolderFileOpener
import com.getdieter.mobile.store.*

/**
 * A synced folder: its status with Sync now, a held deletion to apply or restore, the files of this
 * device's copy, conflicts, the devices that keep it and its pages.
 */
@Composable
internal fun FolderScreen(store: MobileStore, folderId: String) {
    val folder by store.folders.folder.collectAsState()
    val slice = folder.takeIf { it.id == folderId } ?: FolderSlice(id = folderId)
    val files = rememberFolderFiles(store, slice)
    var removing by remember { mutableStateOf<FolderMemberRow?>(null) }
    var addingMachine by remember { mutableStateOf(false) }
    val route = MobileRoute.Folder(folderId)
    Screen(
        ScreenChrome(
            slice.name.ifEmpty { "Folder" },
            actions =
                listOfNotNull(
                    ChromeAction(
                        "folder-sync-now",
                        "Sync now",
                        Glyph.SYNC,
                        enabled = slice.device?.attached == true,
                    ) {
                        store.folders.syncNow(folderId)
                    },
                    ChromeAction(
                        "folder-menu",
                        "More",
                        Glyph.MORE,
                        menu =
                            listOf(
                                MenuSection(
                                    listOfNotNull(
                                        ChromeAction(
                                            "folder-open-device",
                                            FolderSection.DEVICE.title,
                                            Glyph.PHONE,
                                            enabled = slice.device?.attached == true,
                                        ) {
                                            store.push(
                                                MobileRoute.FolderPage(
                                                    folderId,
                                                    FolderSection.DEVICE,
                                                )
                                            )
                                        },
                                        ChromeAction(
                                            "folder-open-trash",
                                            FolderSection.TRASH.title,
                                            Glyph.TRASH,
                                        ) {
                                            store.push(
                                                MobileRoute.FolderPage(
                                                    folderId,
                                                    FolderSection.TRASH,
                                                )
                                            )
                                        },
                                        ChromeAction(
                                            "folder-open-settings",
                                            FolderSection.SETTINGS.title,
                                            Glyph.SETTINGS,
                                        ) {
                                            store.push(
                                                MobileRoute.FolderPage(
                                                    folderId,
                                                    FolderSection.SETTINGS,
                                                )
                                            )
                                        },
                                    )
                                )
                            ),
                    ),
                ),
        )
    ) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("folder-detail"),
            state = listState,
            contentPadding = padding,
        ) {
            if (!slice.found) {
                item("missing") {
                    if (slice.name.isEmpty() && slice.action_error.isEmpty())
                        Box(Modifier.fillMaxWidth().padding(40.dp), Alignment.Center) { Spinner() }
                    else
                        EmptyState(
                            Glyph.FOLDER,
                            "Folder not available",
                            slice.action_error.ifEmpty {
                                "It is not known on this device yet, or it was archived."
                            },
                        )
                }
                return@LazyColumn
            }
            item("hero") { FolderStatusHeader(store, slice) }
            slice.pending_deletions?.let { deletions ->
                item("deletions") {
                    DeletionGuard(deletions) { apply ->
                        store.folders.resolveDeletions(slice.id, apply)
                    }
                }
            }
            if (slice.action_error.isNotEmpty())
                item("error") {
                    Banner(
                        "Something went wrong",
                        slice.action_error,
                        Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                        tone = Tone.WARNING,
                    )
                }
            if (slice.device?.attached == true) {
                item("files-header") { SectionHeader("Files") }
                folderFiles(slice, files) { store.push(MobileRoute.FolderFiles(slice.id, it)) }
            } else
                item("files-off") {
                    SectionHeader("Files")
                    SectionFooter(
                        if (slice.device?.can_attach == true)
                            "Keep this folder on this device to see its files here."
                        else "This device keeps no folders; its machines do."
                    )
                }
            if (slice.conflicts.isNotEmpty())
                item("conflicts") {
                    SectionHeader("Conflicts")
                    Group(slice.conflicts) { conflict, position ->
                        ConflictRow(conflict, position) { keepCopy ->
                            store.folders.resolveConflict(slice.id, conflict.path, keepCopy)
                        }
                    }
                    SectionFooter(
                        "Two devices changed these files at the same time. Keep one version; " +
                            "the other goes to the trash on your machines."
                    )
                }
            item("members-header") { SectionHeader("Devices") }
            itemsIndexed(slice.members, key = { _, member -> "member-${member.member_id}" }) {
                index,
                member ->
                val count = slice.members.size + if (slice.addable_daemons.isEmpty()) 0 else 1
                MemberRow(store, slice, member, Position.of(index, count)) { removing = member }
            }
            if (slice.addable_daemons.isNotEmpty())
                item("add-machine") {
                    ListRow(
                        "Add a machine…",
                        Modifier.testTag("folder-add-machine"),
                        position = Position.of(slice.members.size, slice.members.size + 1),
                        glyph = Glyph.ADD,
                        glyphTint = palette.accent,
                        onClick = { addingMachine = true },
                    )
                }
            if (slice.device?.attached != true && slice.device?.can_attach == true)
                item("keep") {
                    Spacer(Modifier.height(12.dp))
                    ListRow(
                        "Keep on this device…",
                        Modifier.testTag("folder-keep-here"),
                        position = Position.SINGLE,
                        glyph = Glyph.PHONE,
                        glyphTint = palette.accent,
                        onClick = { store.present(MobileRoute.AddFolder(slice.id)) },
                    )
                }
            problems(slice)
            item("pages") {
                SectionHeader("More")
                val pages =
                    listOfNotNull(
                        FolderSection.DEVICE.takeIf { slice.device?.attached == true },
                        FolderSection.TRASH,
                        FolderSection.SETTINGS,
                    )
                Group(pages) { page, position ->
                    ListRow(
                        page.title,
                        Modifier.testTag("folder-page-${page.name.lowercase()}"),
                        position = position,
                        glyph =
                            when (page) {
                                FolderSection.DEVICE -> Glyph.PHONE
                                FolderSection.TRASH -> Glyph.TRASH
                                FolderSection.SETTINGS -> Glyph.SETTINGS
                            },
                        value =
                            when (page) {
                                FolderSection.DEVICE -> slice.device?.direction_label
                                FolderSection.TRASH ->
                                    slice.trash?.rows?.size?.takeIf { it > 0 }?.toString()
                                FolderSection.SETTINGS -> null
                            },
                        accessory = Accessory.CHEVRON,
                        onClick = { store.showFrom(route, MobileRoute.FolderPage(slice.id, page)) },
                    )
                }
            }
        }
    }
    files.Overlays()
    removing?.let { member ->
        ConfirmDialog(
            "Stop syncing on ${member.name}?",
            "The folder's files stay on ${member.name}; it just stops syncing them.",
            "Stop syncing",
            {
                store.folders.detachDaemon(slice.id, member.member_id)
                removing = null
            },
            { removing = null },
            destructive = true,
        )
    }
    if (addingMachine) AddMachineSheet(store, slice) { addingMachine = false }
}

/** A directory below a folder's root, with its breadcrumbs. */
@Composable
internal fun FolderFilesScreen(store: MobileStore, folderId: String, path: String) {
    val folder by store.folders.folder.collectAsState()
    val slice = folder.takeIf { it.id == folderId } ?: FolderSlice(id = folderId)
    val files = rememberFolderFiles(store, slice)
    val shows = slice.directory == path
    Screen(
        ScreenChrome(
            path.substringAfterLast('/').ifEmpty { slice.name },
            subtitle = slice.name,
            actions =
                listOf(
                    ChromeAction(
                        "folder-sync-now",
                        "Sync now",
                        Glyph.SYNC,
                        enabled = slice.device?.attached == true,
                    ) {
                        store.folders.syncNow(folderId)
                    }
                ),
        )
    ) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("folder-files"),
            state = listState,
            contentPadding = padding,
        ) {
            item("crumbs") {
                Row(
                    Modifier.fillMaxWidth()
                        .horizontalScroll(rememberScrollState())
                        .padding(horizontal = ScreenMargin + 4.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    slice.breadcrumbs.forEachIndexed { index, crumb ->
                        if (index > 0)
                            Icon(
                                Glyph.CHEVRON_RIGHT,
                                null,
                                tint = palette.tertiaryLabel,
                                size = 14.dp,
                            )
                        Text(
                            crumb.title,
                            Modifier.pressable(
                                    onClick = {
                                        if (crumb.path.isEmpty()) {
                                            val stack = store.routes.value.stack
                                            val detail = MobileRoute.Folder(folderId)
                                            if (detail in stack)
                                                store.popTo(
                                                    store.routes.value.tab,
                                                    stack.indexOf(detail) + 1,
                                                )
                                            else store.replaceTop(detail)
                                        } else if (crumb.path != path)
                                            store.replaceTop(
                                                MobileRoute.FolderFiles(folderId, crumb.path)
                                            )
                                    }
                                )
                                .padding(horizontal = 4.dp, vertical = 2.dp)
                                .testTag("folder-crumb-${crumb.path.ifEmpty { "root" }}"),
                            style = type.subheadline,
                            color =
                                if (index == slice.breadcrumbs.lastIndex) palette.label
                                else palette.accent,
                            maxLines = 1,
                        )
                    }
                }
            }
            if (!shows)
                item("loading") {
                    Box(Modifier.fillMaxWidth().padding(32.dp), Alignment.Center) { Spinner() }
                }
            else folderFiles(slice, files) { store.push(MobileRoute.FolderFiles(folderId, it)) }
        }
    }
    files.Overlays()
}

/** Tapping files: download what is missing, then open, share or free a downloaded one. */
@Stable
internal class FolderFiles(
    private val store: MobileStore,
    private val slice: () -> FolderSlice,
    private val open: (FolderFileRef, Boolean) -> Unit,
) {
    var actions by mutableStateOf<FolderFileRow?>(null)
    /** A file the person asked for; its actions open once it is downloaded. */
    var requested by mutableStateOf("")

    fun tap(row: FolderFileRow) {
        if (row.downloaded) actions = row
        else {
            requested = row.path
            store.folders.download(slice().id, row.path)
        }
    }

    fun ref(row: FolderFileRow): FolderFileRef? {
        val location = slice().device?.settings?.location?.ifEmpty { null } ?: return null
        return FolderFileRef(location, row.disk_path.ifEmpty { row.path }, row.name)
    }

    @Composable
    fun Overlays() {
        val files = slice().files
        LaunchedEffect(files, requested) {
            if (requested.isEmpty()) return@LaunchedEffect
            files
                .firstOrNull { it.path == requested && it.downloaded }
                ?.let {
                    requested = ""
                    actions = it
                }
        }
        val row = actions ?: return
        Sheet(row.name, { actions = null }, size = SheetSize.MEDIUM) {
            Group(listOf("open", "share", "evict")) { action, position ->
                when (action) {
                    "open" ->
                        ListRow(
                            "Open",
                            Modifier.testTag("folder-file-open"),
                            position = position,
                            glyph = Glyph.OPEN,
                            onClick = {
                                actions = null
                                ref(row)?.let { open(it, false) }
                            },
                        )
                    "share" ->
                        ListRow(
                            "Share…",
                            Modifier.testTag("folder-file-share"),
                            position = position,
                            glyph = Glyph.SHARE,
                            onClick = {
                                actions = null
                                ref(row)?.let { open(it, true) }
                            },
                        )
                    else ->
                        ListRow(
                            "Free up space",
                            Modifier.testTag("folder-file-evict"),
                            position = position,
                            subtitle =
                                "Remove it from this device; it stays listed and downloads on tap",
                            glyph = Glyph.PULL,
                            onClick = {
                                actions = null
                                store.folders.evict(slice().id, row.path)
                            },
                        )
                }
            }
        }
    }
}

@Composable
internal fun rememberFolderFiles(store: MobileStore, slice: FolderSlice): FolderFiles {
    val current by rememberUpdatedState(slice)
    val opener = rememberFolderFileOpener { store.error.value = it }
    return remember(store) { FolderFiles(store, { current }, opener) }
}

/** The rows of the shown directory: directories open, files download or offer their actions. */
internal fun LazyListScope.folderFiles(
    slice: FolderSlice,
    files: FolderFiles,
    openDirectory: (String) -> Unit,
) {
    if (slice.files.isEmpty())
        item("files-empty") {
            SectionFooter(
                if (slice.directory.isEmpty())
                    "No files yet. Files added on any member appear here."
                else "This folder is empty."
            )
        }
    itemsIndexed(slice.files, key = { _, row -> "file-${row.path}" }) { index, row ->
        val subtitle =
            listOf(row.size_label, row.badge).filter { it.isNotBlank() }.joinToString(" · ")
        ListRow(
            row.name,
            Modifier.testTag("folder-file-${row.path}"),
            position = Position.of(index, slice.files.size),
            subtitle = subtitle.ifEmpty { null },
            glyph = fileGlyph(row.name, row.directory),
            glyphTint = if (row.conflict) palette.warning else null,
            accessory = if (row.directory) Accessory.CHEVRON else Accessory.NONE,
            trailing =
                if (!row.directory && !row.downloaded)
                    ({
                        if (files.requested == row.path || row.badge == "Waiting to download")
                            Spinner(Modifier.size(16.dp))
                        else
                            Icon(
                                Glyph.PULL,
                                "Not downloaded",
                                Modifier.testTag("folder-file-cloud-${row.path}"),
                                tint = palette.tertiaryLabel,
                                size = 20.dp,
                            )
                    })
                else null,
            onClick = { if (row.directory) openDirectory(row.path) else files.tap(row) },
        )
    }
    if (slice.files_truncated)
        item("files-truncated") { SectionFooter("Only the first 500 entries are listed.") }
}

@Composable
private fun FolderStatusHeader(store: MobileStore, slice: FolderSlice) {
    val device = slice.device ?: FolderDeviceState()
    val lines = buildList {
        if (device.attached)
            add(
                listOf(
                        device.home_label.takeIf { it.isNotBlank() }?.let { "Home: $it" },
                        device.direction_label,
                        slice.project_name.takeIf { it.isNotBlank() }?.let { "linked to $it" },
                    )
                    .filterNotNull()
                    .filter { it.isNotBlank() }
                    .joinToString(" · ")
            )
        else if (slice.project_name.isNotBlank()) add("Linked to ${slice.project_name}")
        if (device.reason.isNotBlank() && device.reason != slice.status) add(device.reason)
        add(device.pending_label)
        add(device.usage_label)
        if (device.last_sync.isNotBlank() && device.attached) add("Last sync ${device.last_sync}")
    }
    FolderHero(slice.status.ifEmpty { "Not synced yet" }, tone = slice.tone, lines = lines) {
        if (device.attached) {
            DButton(
                "Sync now",
                { store.folders.syncNow(slice.id) },
                Modifier.testTag("folder-hero-sync"),
                glyph = Glyph.SYNC,
                loading = device.syncing,
            )
            if (device.direction == FolderDirection.FOLDER_DIRECTION_PAUSED)
                DButton(
                    "Resume",
                    {
                        store.folders.setDirection(
                            slice.id,
                            device.settings?.direction?.takeIf {
                                it != FolderDirection.FOLDER_DIRECTION_PAUSED &&
                                    it != FolderDirection.FOLDER_DIRECTION_UNSPECIFIED
                            } ?: FolderDirection.FOLDER_DIRECTION_TWO_WAY,
                        )
                    },
                    kind = ButtonKind.TONAL,
                )
        } else {
            if (device.can_attach)
                DButton(
                    "Keep on this device",
                    { store.present(MobileRoute.AddFolder(slice.id)) },
                    Modifier.testTag("folder-hero-keep"),
                    kind = ButtonKind.TONAL,
                    glyph = Glyph.PHONE,
                )
            // Not on this device: a machine that keeps it shows its copy in Files.
            for (member in slice.members.filter { it.daemon && it.online }.take(2)) DButton(
                "Browse on ${member.name}",
                {
                    store.push(
                        MobileRoute.FilePath(
                            "",
                            file = false,
                            daemonId = member.member_id,
                            folderId = slice.id,
                        )
                    )
                },
                Modifier.testTag("folder-hero-browse-${member.member_id}"),
                kind = ButtonKind.TONAL,
                glyph = Glyph.FOLDER_OPEN,
            )
        }
    }
}

/** The deletion guard holds a batch: Apply deletes, Restore brings the files back. */
@Composable
internal fun DeletionGuard(deletions: FolderDeletionsRow, resolve: (apply: Boolean) -> Unit) {
    var confirming by remember { mutableStateOf(false) }
    Column(Modifier.testTag("folder-deletions")) {
        Banner(
            deletions.title,
            buildString {
                append(deletions.detail)
                val sample = deletions.sample.take(3)
                if (sample.isNotEmpty()) {
                    append("\n")
                    append(sample.joinToString(", "))
                    if (deletions.count > sample.size)
                        append(" and ${deletions.count - sample.size} more")
                }
            },
            Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
            tone = Tone.DANGER,
            glyph = Glyph.WARNING,
        )
        Row(
            Modifier.padding(horizontal = ScreenMargin + 4.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            DButton(
                "Restore",
                { resolve(false) },
                Modifier.testTag("folder-deletions-restore"),
                kind = ButtonKind.TONAL,
            )
            DButton(
                "Apply",
                { confirming = true },
                Modifier.testTag("folder-deletions-apply"),
                kind = ButtonKind.DESTRUCTIVE,
            )
        }
    }
    if (confirming)
        ConfirmDialog(
            deletions.title,
            if (deletions.source == "local")
                "The files stay deleted here and are deleted on every member. Your machines keep " +
                    "them in their trash."
            else "The files are deleted from this device too.",
            "Delete",
            {
                confirming = false
                resolve(true)
            },
            { confirming = false },
            destructive = true,
        )
}

@Composable
private fun ConflictRow(
    conflict: FolderConflictRow,
    position: Position,
    keep: (copy: Boolean) -> Unit,
) {
    ListRow(
        conflict.original.substringAfterLast('/').ifEmpty { conflict.path },
        Modifier.testTag("folder-conflict-${conflict.path}"),
        position = position,
        subtitle = conflict.detail,
        glyph = Glyph.WARNING,
        glyphTint = palette.warning,
        trailing = {
            Row {
                DButton(
                    "Keep this",
                    { keep(true) },
                    Modifier.testTag("folder-conflict-keep-copy"),
                    kind = ButtonKind.PLAIN,
                    enabled = conflict.downloaded,
                )
                DButton(
                    "Keep original",
                    { keep(false) },
                    Modifier.testTag("folder-conflict-keep-original"),
                    kind = ButtonKind.PLAIN,
                )
            }
        },
    )
}

@Composable
private fun MemberRow(
    store: MobileStore,
    slice: FolderSlice,
    member: FolderMemberRow,
    position: Position,
    remove: () -> Unit,
) {
    val subtitle =
        listOf(
                member.mode_label,
                member.status,
                member.home.takeIf { !member.daemon && it.isNotBlank() }?.let { "via $it" },
                member.last_sync.takeIf { member.daemon && it.isNotBlank() },
            )
            .filter { !it.isNullOrBlank() }
            .joinToString(" · ")
    val menu = rememberMenuState()
    val actions =
        if (!member.daemon) emptyList()
        else
            listOf(
                MenuSection(
                    listOf(
                            FolderMode.FOLDER_MODE_TWO_WAY,
                            FolderMode.FOLDER_MODE_SEND_ONLY,
                            FolderMode.FOLDER_MODE_RECEIVE_ONLY,
                        )
                        .map { mode ->
                            ChromeAction(
                                "member-mode-${mode.name.lowercase()}",
                                com.getdieter.core.folders.FolderSettings.modeLabel(mode),
                                checked = member.mode == mode,
                            ) {
                                store.folders.setDaemonMode(slice.id, member.member_id, mode)
                            }
                        },
                    title = "Mode",
                ),
                MenuSection(
                    listOfNotNull(
                        ChromeAction(
                            "member-pause",
                            if (member.paused) "Resume" else "Pause",
                            if (member.paused) Glyph.PLAY else Glyph.PAUSE,
                        ) {
                            store.folders.pauseDaemon(slice.id, member.member_id, !member.paused)
                        },
                        ChromeAction("member-rescan", "Scan now", Glyph.REFRESH) {
                            store.folders.rescanDaemon(slice.id, member.member_id)
                        },
                        if (member.state == FolderState.FOLDER_STATE_ATTENTION)
                            ChromeAction("member-restore", "Restore held deletions", Glyph.UNDO) {
                                store.folders.resolveDeletions(slice.id, false, member.member_id)
                            }
                        else null,
                        if (member.state == FolderState.FOLDER_STATE_ATTENTION)
                            ChromeAction(
                                "member-apply",
                                "Apply held deletions",
                                Glyph.TRASH,
                                destructive = true,
                            ) {
                                store.folders.resolveDeletions(slice.id, true, member.member_id)
                            }
                        else null,
                        ChromeAction(
                            "member-detach",
                            "Stop syncing here…",
                            Glyph.CLOSE,
                            destructive = true,
                        ) {
                            remove()
                        },
                    )
                ),
            )
    MenuAnchor(menu) {
        ListRow(
            if (member.this_device) "${member.name} (this device)" else member.name,
            Modifier.testTag("folder-member-${member.member_id}"),
            position = position,
            subtitle = subtitle,
            glyph = if (member.daemon) Glyph.SERVER else Glyph.PHONE,
            tile = if (member.online) palette.info else palette.tertiaryLabel,
            trailing = { StatusDot(member.tone) },
            onClick =
                when {
                    member.this_device -> {
                        { store.push(MobileRoute.FolderPage(slice.id, FolderSection.DEVICE)) }
                    }
                    actions.isNotEmpty() -> {
                        { menu.show(actions) }
                    }
                    else -> null
                },
        )
    }
}

/** Errors, unsyncable paths, local changes and remote changes not applied here. */
private fun LazyListScope.problems(slice: FolderSlice) {
    val groups =
        listOf(
                "Local changes" to
                    slice.local_changes.map {
                        FolderProblemRow(path = it, message = "Not sent: download only")
                    },
                "Not in sync" to
                    slice.out_of_sync.map {
                        FolderProblemRow(path = it, message = "Not applied: upload only")
                    },
                "Can't sync here" to slice.unsyncable,
                "Errors" to slice.errors,
            )
            .filter { it.second.isNotEmpty() }
    for ((title, rows) in groups) {
        item("problems-$title") {
            SectionHeader(title)
            Group(rows.take(20)) { row, position ->
                ListRow(
                    row.path.ifEmpty { slice.name },
                    position = position,
                    subtitle = row.message,
                    glyph = Glyph.INFO,
                    titleMaxLines = 1,
                )
            }
            if (rows.size > 20) SectionFooter("And ${rows.size - 20} more.")
        }
    }
}

/** Binds another machine's directory to the folder. */
@Composable
private fun AddMachineSheet(store: MobileStore, slice: FolderSlice, dismiss: () -> Unit) {
    var daemon by remember {
        mutableStateOf(slice.addable_daemons.firstOrNull { it.online }?.daemon_id.orEmpty())
    }
    var path by remember { mutableStateOf("") }
    var browsing by remember { mutableStateOf(false) }
    Sheet(
        "Add a machine",
        dismiss,
        confirm =
            ChromeAction(
                "add-machine",
                "Add",
                Glyph.CHECK,
                enabled = daemon.isNotEmpty() && path.isNotBlank(),
            ) {
                store.folders.attachDaemon(slice.id, daemon, path, FolderMode.FOLDER_MODE_TWO_WAY)
                dismiss()
            },
    ) {
        Group(listOf(0)) { _, position ->
            PickerRow(
                "Machine",
                slice.addable_daemons.firstOrNull { it.daemon_id == daemon }?.label.orEmpty(),
                slice.addable_daemons.map { it.daemon_id to it.label },
                daemon,
                slice.addable_daemons.isNotEmpty(),
                position,
                Glyph.SERVER,
            ) {
                daemon = it
                path = ""
            }
        }
        DaemonPathField(path, { path = it }, daemon.isNotEmpty()) { browsing = true }
        SectionFooter(
            "Files already in that directory are merged; differing files keep both versions."
        )
    }
    if (browsing) DaemonDirectoryPicker(store, daemon, path, { path = it }) { browsing = false }
}

/** A daemon path with Browse…, as the add flows enter it. */
@Composable
internal fun DaemonPathField(
    path: String,
    onChange: (String) -> Unit,
    enabled: Boolean,
    browse: () -> Unit,
) {
    FormColumn {
        MobileTextField(
            path,
            onChange,
            Modifier.fillMaxWidth().testTag("folder-daemon-path"),
            label = { Text("Directory on the machine") },
            placeholder = { Text("~/Dieter/Inbox") },
            singleLine = true,
        )
        DButton(
            "Browse…",
            browse,
            Modifier.fillMaxWidth().testTag("folder-daemon-browse"),
            kind = ButtonKind.TONAL,
            glyph = Glyph.FOLDER_OPEN,
            enabled = enabled,
        )
    }
}

/** Short text that never wraps, for list values. */
@Composable
internal fun ValueText(text: String) {
    Text(
        text,
        style = type.body,
        color = palette.secondaryLabel,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

internal val SliceTone.isQuiet: Boolean
    get() = this == SliceTone.TONE_NEUTRAL
