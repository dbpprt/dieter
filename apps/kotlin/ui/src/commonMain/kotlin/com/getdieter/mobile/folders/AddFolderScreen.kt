package com.getdieter.mobile.folders

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.FolderDirection
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.platform.rememberFolderLocationPicker
import com.getdieter.mobile.store.*

/** The add-folder flow's steps, in order. */
internal enum class AddFolderStep(val title: String) {
    START("Add folder"),
    MACHINE("Machine"),
    LOCATION("This device"),
    DIRECTION("Direction"),
    REVIEW("Review"),
}

/**
 * Add folder: create a folder or join one → the machine that keeps it and a directory there → where
 * it lives on this device → its direction here → review. Joining a folder that is already on a
 * machine skips the machine.
 */
@Composable
internal fun AddFolderScreen(store: MobileStore, joinId: String) {
    val list by store.folders.list.collectAsState()
    val workspace by store.workspace.slice.collectAsState()
    val busy by store.busy.collectAsState()
    var step by rememberSaveable {
        mutableStateOf(if (joinId.isEmpty()) AddFolderStep.START else AddFolderStep.LOCATION)
    }
    var joining by rememberSaveable { mutableStateOf(joinId.isNotEmpty()) }
    var join by rememberSaveable { mutableStateOf(joinId) }
    var name by rememberSaveable { mutableStateOf("") }
    var project by rememberSaveable { mutableStateOf("") }
    var daemon by rememberSaveable { mutableStateOf("") }
    var path by rememberSaveable { mutableStateOf("") }
    var onDevice by rememberSaveable { mutableStateOf(true) }
    var location by rememberSaveable { mutableStateOf("") }
    var locationLabel by rememberSaveable { mutableStateOf("") }
    var direction by rememberSaveable { mutableStateOf(FolderDirection.FOLDER_DIRECTION_TWO_WAY) }
    var removeAfterUpload by rememberSaveable { mutableStateOf(false) }
    var browsing by remember { mutableStateOf(false) }
    val picker =
        rememberFolderLocationPicker(
            onPicked = { picked, label ->
                location = picked
                locationLabel = label
            },
            onError = { store.error.value = it },
        )
    val joinable = list.folders.filter { !it.on_device }
    val daemons = list.daemons
    LaunchedEffect(daemons) {
        if (daemon.isEmpty()) daemons.firstOrNull { it.online }?.let { daemon = it.daemon_id }
    }
    val capable = list.device_capable
    // Joining keeps the folder's machines; creating needs one.
    val steps =
        listOfNotNull(
            AddFolderStep.START.takeIf { joinId.isEmpty() },
            AddFolderStep.MACHINE.takeIf { !joining },
            AddFolderStep.LOCATION.takeIf { capable },
            AddFolderStep.DIRECTION.takeIf { capable && onDevice },
            AddFolderStep.REVIEW,
        )
    val index = steps.indexOf(step).coerceAtLeast(0)
    val ready =
        when (step) {
            AddFolderStep.START -> if (joining) join.isNotEmpty() else name.isNotBlank()
            AddFolderStep.MACHINE -> daemon.isNotEmpty() && path.isNotBlank()
            else -> true
        }
    val last = index == steps.lastIndex
    fun finish() {
        store.folders.add(
            AddFolderPlan(
                join = if (joining) join else "",
                name = name,
                projectId = project,
                daemonId = if (joining) "" else daemon,
                path = if (joining) "" else path,
                onDevice = capable && onDevice,
                location = location,
                locationLabel = locationLabel,
                direction = direction,
                removeAfterUpload =
                    removeAfterUpload && direction == FolderDirection.FOLDER_DIRECTION_UPLOAD_ONLY,
            )
        ) { folderId ->
            store.dismiss()
            store.openMore(MobileRoute.Tool(ToolPage.FOLDERS))
            store.showFrom(MobileRoute.Tool(ToolPage.FOLDERS), MobileRoute.Folder(folderId))
        }
    }
    Screen(
        ScreenChrome(
            step.title,
            subtitle = "Step ${index + 1} of ${steps.size}",
            cancel = ChromeAction("add-folder-cancel", "Cancel", Glyph.CLOSE) { store.dismiss() },
            confirm =
                ChromeAction(
                    "add-folder-next",
                    if (last) "Add" else "Next",
                    if (last) Glyph.CHECK else Glyph.CHEVRON_RIGHT,
                    enabled = ready && !busy,
                ) {
                    if (last) finish() else step = steps[index + 1]
                },
        )
    ) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("add-folder-${step.name.lowercase()}"),
            state = listState,
            contentPadding = padding,
        ) {
            when (step) {
                AddFolderStep.START -> {
                    item("mode") {
                        Spacer(Modifier.height(8.dp))
                        SettingsCell {
                            Segmented(
                                listOf("Create a folder", "Join a folder"),
                                if (joining) 1 else 0,
                                { joining = it == 1 },
                                testTagPrefix = "add-folder-mode",
                            )
                        }
                    }
                    if (!joining)
                        item("create") {
                            FormColumn {
                                MobileTextField(
                                    name,
                                    { name = it },
                                    Modifier.fillMaxWidth().testTag("add-folder-name"),
                                    label = { Text("Name") },
                                    placeholder = { Text("Inbox") },
                                    singleLine = true,
                                )
                            }
                            PickerRow(
                                "Linked project",
                                workspace.projects.firstOrNull { it.id == project }?.name ?: "None",
                                listOf("" to "None") + workspace.projects.map { it.id to it.name },
                                project,
                                true,
                                Position.SINGLE,
                                Glyph.PROJECTS,
                                tag = "add-folder-project",
                            ) {
                                project = it
                            }
                            SectionFooter(
                                "Agents of a linked project learn where the folder is on its machines."
                            )
                        }
                    else
                        item("join") {
                            SectionHeader("Folders not on this device")
                            if (joinable.isEmpty())
                                SectionFooter(
                                    "Every folder of this account is already on this device."
                                )
                            Group(joinable) { row, position ->
                                ListRow(
                                    row.name,
                                    Modifier.testTag("add-folder-join-${row.id}"),
                                    position = position,
                                    subtitle = row.members,
                                    glyph = Glyph.FOLDER,
                                    accessory =
                                        if (row.id == join) Accessory.CHECK else Accessory.NONE,
                                    onClick = { join = row.id },
                                )
                            }
                        }
                }
                AddFolderStep.MACHINE ->
                    item("machine") {
                        SectionHeader("The machine that keeps it")
                        PickerRow(
                            "Machine",
                            daemons.firstOrNull { it.daemon_id == daemon }?.label.orEmpty(),
                            daemons.map {
                                it.daemon_id to (it.label + if (it.online) "" else " (offline)")
                            },
                            daemon,
                            daemons.isNotEmpty(),
                            Position.SINGLE,
                            Glyph.SERVER,
                            tag = "add-folder-machine",
                        ) {
                            daemon = it
                            path = ""
                        }
                        DaemonPathField(path, { path = it }, daemon.isNotEmpty()) {
                            browsing = true
                        }
                        SectionFooter(
                            "Files already in that directory join the folder. Your home directory, " +
                                "Dieter's data and registered checkouts cannot be used."
                        )
                    }
                AddFolderStep.LOCATION -> {
                    item("keep") {
                        Spacer(Modifier.height(8.dp))
                        ListRow(
                            "Keep a copy on this device",
                            position = Position.SINGLE,
                            trailing = {
                                DSwitch(
                                    onDevice,
                                    { onDevice = it },
                                    Modifier.testTag("add-folder-on-device"),
                                )
                            },
                        )
                    }
                    if (onDevice)
                        item("where") {
                            SectionHeader("Where it lives here")
                            if (picker == null)
                                ListRow(
                                    "On this device",
                                    position = Position.SINGLE,
                                    subtitle = "Visible in the Files app under Dieter",
                                    glyph = Glyph.FOLDER,
                                    accessory = Accessory.CHECK,
                                )
                            else
                                Group(listOf(true, false)) { shared, position ->
                                    if (shared)
                                        ListRow(
                                            "Shared folder…",
                                            Modifier.testTag("add-folder-location-shared"),
                                            position = position,
                                            subtitle =
                                                locationLabel.ifEmpty {
                                                    "Choose a folder other apps can see"
                                                },
                                            glyph = Glyph.FOLDER_OPEN,
                                            accessory =
                                                if (location.isNotEmpty()) Accessory.CHECK
                                                else Accessory.NONE,
                                            onClick = picker,
                                        )
                                    else
                                        ListRow(
                                            "Private to Dieter",
                                            Modifier.testTag("add-folder-location-private"),
                                            position = position,
                                            subtitle = "Only Dieter and the share sheet reach it",
                                            glyph = Glyph.LOCK,
                                            accessory =
                                                if (location.isEmpty()) Accessory.CHECK
                                                else Accessory.NONE,
                                            onClick = {
                                                location = ""
                                                locationLabel = ""
                                            },
                                        )
                                }
                        }
                }
                AddFolderStep.DIRECTION ->
                    item("direction") {
                        Spacer(Modifier.height(8.dp))
                        SettingsCell {
                            Segmented(
                                folderDirections.map { it.shortLabel() },
                                folderDirections.indexOf(direction).coerceAtLeast(0),
                                { direction = folderDirections[it] },
                                testTagPrefix = "add-folder-direction",
                            )
                            Text(
                                direction.detail(),
                                style = type.footnote,
                                color = palette.secondaryLabel,
                            )
                        }
                        if (direction == FolderDirection.FOLDER_DIRECTION_UPLOAD_ONLY) {
                            Spacer(Modifier.height(8.dp))
                            ListRow(
                                "Remove from this device after upload",
                                position = Position.SINGLE,
                                subtitle =
                                    "Inbox style: uploaded files are freed here, never deleted",
                                trailing = {
                                    DSwitch(
                                        removeAfterUpload,
                                        { removeAfterUpload = it },
                                        Modifier.testTag("add-folder-remove-after-upload"),
                                    )
                                },
                            )
                        }
                    }
                AddFolderStep.REVIEW ->
                    item("review") {
                        SectionHeader("Review")
                        val joined = list.folders.firstOrNull { it.id == join }
                        val rows =
                            listOfNotNull(
                                "Folder" to
                                    (if (joining) joined?.name ?: "Folder" else name.trim()),
                                if (!joining)
                                    "Machine" to
                                        ("${daemons.firstOrNull { it.daemon_id == daemon }?.label.orEmpty()} · ${path.trim()}")
                                else "Machines" to joined?.members.orEmpty(),
                                if (capable)
                                    "This device" to
                                        (if (!onDevice) "Not kept here"
                                        else
                                            locationLabel.ifEmpty {
                                                if (picker == null) "On this device"
                                                else "Private to Dieter"
                                            })
                                else null,
                                if (capable && onDevice) "Direction" to direction.label() else null,
                                project
                                    .takeIf { it.isNotEmpty() && !joining }
                                    ?.let { id ->
                                        "Linked project" to
                                            workspace.projects
                                                .firstOrNull { it.id == id }
                                                ?.name
                                                .orEmpty()
                                    },
                            )
                        Group(rows) { (title, value), position ->
                            ListRow(
                                title,
                                position = position,
                                subtitle = value,
                                subtitleMaxLines = 3,
                            )
                        }
                        if (busy) SectionFooter("Adding the folder…")
                    }
            }
            if (index > 0)
                item("back") {
                    Spacer(Modifier.height(12.dp))
                    DButton(
                        "Back",
                        { step = steps[index - 1] },
                        Modifier.padding(horizontal = ScreenMargin).testTag("add-folder-back"),
                        kind = ButtonKind.PLAIN,
                        glyph = Glyph.BACK,
                    )
                }
        }
    }
    if (browsing) DaemonDirectoryPicker(store, daemon, path, { path = it }) { browsing = false }
}
