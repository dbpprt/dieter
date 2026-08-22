package com.dbpprt.nauclio.ui

import android.view.KeyEvent
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Keyboard
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.dbpprt.nauclio.ui.theme.NauclioAbyss
import com.dbpprt.nauclio.ui.theme.NauclioAegean
import com.dbpprt.nauclio.ui.theme.NauclioCoral
import com.dbpprt.nauclio.ui.theme.NauclioMuted
import com.dbpprt.nauclio.ui.theme.NauclioOutline
import com.dbpprt.nauclio.ui.theme.NauclioSeafoam
import com.dbpprt.nauclio.ui.theme.NauclioSurface
import com.dbpprt.nauclio.ui.theme.NauclioSurfaceHigh
import com.dbpprt.nauclio.ui.theme.NauclioText
import com.dbpprt.nauclio.v1.Project
import com.dbpprt.nauclio.v1.Terminal

private val TerminalCanvas = Color(0xFF08090D)
private val TerminalBar = Color(0xFF111218)

@Composable
fun TerminalsScreen(
    state: NauclioUiState,
    model: NauclioViewModel,
    expanded: Boolean,
    contentPadding: PaddingValues,
    modifier: Modifier = Modifier,
) {
    var renameTerminal by remember { mutableStateOf<Terminal?>(null) }
    var closingTerminal by remember { mutableStateOf<Terminal?>(null) }
    var terminalView by remember(state.selectedTerminalId) { mutableStateOf<RemoteTerminalView?>(null) }
    var controlArmed by remember(state.selectedTerminalId) { mutableStateOf(false) }
    val selected = state.selectedTerminal

    Column(
        modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)
            .padding(bottom = contentPadding.calculateBottomPadding())
            .statusBarsPadding(),
    ) {
        TerminalHeader(
            terminalCount = state.terminals.size,
            connected = state.terminalStreamConnected,
            loading = state.terminalLoading,
            onRefresh = model::loadTerminals,
            onCreate = model::showTerminalCreate,
        )
        if (state.terminals.isNotEmpty()) {
            TerminalTabs(
                terminals = state.terminals,
                selectedId = state.selectedTerminalId,
                onSelect = model::selectTerminal,
                onRename = { renameTerminal = it },
                onClose = { closingTerminal = it },
            )
        }
        state.error?.takeIf(String::isNotBlank)?.let { message ->
            Surface(
                color = NauclioCoral.copy(alpha = 0.10f),
                contentColor = NauclioCoral,
                shape = RoundedCornerShape(10.dp),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 5.dp),
            ) {
                Text(
                    message,
                    fontSize = 11.sp,
                    lineHeight = 15.sp,
                    modifier = Modifier.padding(horizontal = 11.dp, vertical = 8.dp),
                )
            }
        }
        if (selected == null) {
            TerminalEmptyState(
                loading = state.terminalLoading,
                hasProjects = state.projects.isNotEmpty(),
                onCreate = model::showTerminalCreate,
            )
        } else {
            val screen = state.terminalScreens[selected.id] ?: TerminalScreenState()
            val running = selected.status == "running"
            Surface(
                color = TerminalCanvas,
                border = BorderStroke(1.dp, NauclioOutline.copy(alpha = 0.72f)),
                shape = if (expanded) RoundedCornerShape(18.dp) else RoundedCornerShape(0.dp),
                modifier = Modifier.weight(1f).fillMaxWidth()
                    .padding(horizontal = if (expanded) 14.dp else 0.dp),
            ) {
                key(selected.id) {
                    AndroidView(
                        factory = { context ->
                            RemoteTerminalView(context).also { view ->
                                terminalView = view
                                view.onInput = { bytes -> if (running) model.sendTerminalInput(selected.id, bytes) }
                                view.onResize = { columns, rows -> model.resizeTerminal(selected.id, columns, rows) }
                                view.onControlChanged = { controlArmed = it }
                            }
                        },
                        update = { view ->
                            terminalView = view
                            view.onInput = { bytes -> if (running) model.sendTerminalInput(selected.id, bytes) }
                            view.onResize = { columns, rows -> model.resizeTerminal(selected.id, columns, rows) }
                            view.applyScreen(screen)
                        },
                        modifier = Modifier.fillMaxSize().testTag("terminal-canvas")
                            .semantics {
                                contentDescription = "Terminal ${selected.name}; ${if (running) "running" else selected.status}"
                            },
                    )
                }
            }
            TerminalAccessoryBar(
                enabled = running,
                controlArmed = controlArmed,
                onControl = { terminalView?.toggleControl() },
                onKey = { terminalView?.sendKeyCode(it) },
                onBytes = { terminalView?.sendBytes(it) },
                onPaste = { terminalView?.pasteClipboard() },
            )
            TerminalStatusBar(
                terminal = selected,
                project = state.projects.firstOrNull { it.id == selected.projectId },
                hostname = state.projectHosts[selected.projectId]?.hostname.orEmpty(),
                connected = state.terminalStreamConnected,
            )
        }
    }

    if (state.terminalCreateVisible) {
        NewTerminalSheet(state, model)
    }
    renameTerminal?.let { terminal ->
        RenameTerminalDialog(
            terminal = terminal,
            onDismiss = { renameTerminal = null },
            onRename = {
                model.renameTerminal(terminal.id, it)
                renameTerminal = null
            },
        )
    }
    closingTerminal?.let { terminal ->
        AlertDialog(
            onDismissRequest = { closingTerminal = null },
            icon = { Icon(Icons.Outlined.Close, contentDescription = null, tint = NauclioCoral) },
            title = { Text("Close ${terminal.name}?") },
            text = { Text("This ends the persistent daemon session and its running shell. This cannot be undone.") },
            dismissButton = { TextButton(onClick = { closingTerminal = null }) { Text("Keep open") } },
            confirmButton = {
                TextButton(
                    onClick = {
                        model.closeTerminal(terminal.id)
                        closingTerminal = null
                    },
                ) { Text("Close terminal", color = NauclioCoral) }
            },
        )
    }
}

@Composable
private fun TerminalHeader(
    terminalCount: Int,
    connected: Boolean,
    loading: Boolean,
    onRefresh: () -> Unit,
    onCreate: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().padding(start = 18.dp, top = 12.dp, end = 10.dp, bottom = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Surface(color = NauclioAegean.copy(alpha = 0.12f), shape = RoundedCornerShape(13.dp), modifier = Modifier.size(42.dp)) {
            Box(contentAlignment = Alignment.Center) {
                Icon(Icons.Outlined.Terminal, contentDescription = null, tint = NauclioAegean, modifier = Modifier.size(22.dp))
            }
        }
        Spacer(Modifier.width(11.dp))
        Column(Modifier.weight(1f)) {
            Text("Terminals", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(6.dp).background(if (connected) NauclioSeafoam else NauclioMuted, CircleShape))
                Spacer(Modifier.width(6.dp))
                Text(
                    when {
                        loading -> "Syncing persistent sessions…"
                        terminalCount == 0 -> "Daemon-owned · survive app disconnects"
                        else -> "$terminalCount persistent ${if (terminalCount == 1) "session" else "sessions"} · ${if (connected) "live" else "reconnecting"}"
                    },
                    color = NauclioMuted,
                    fontSize = 11.sp,
                )
            }
        }
        IconButton(onClick = onRefresh, enabled = !loading) {
            Icon(Icons.Outlined.Refresh, contentDescription = "Refresh terminals", tint = NauclioMuted)
        }
        Surface(
            onClick = onCreate,
            color = NauclioAegean,
            contentColor = NauclioAbyss,
            shape = RoundedCornerShape(13.dp),
            modifier = Modifier.size(42.dp).testTag("new-terminal"),
        ) { Box(contentAlignment = Alignment.Center) { Icon(Icons.Default.Add, "New terminal") } }
    }
}

@Composable
private fun TerminalTabs(
    terminals: List<Terminal>,
    selectedId: String?,
    onSelect: (String) -> Unit,
    onRename: (Terminal) -> Unit,
    onClose: (Terminal) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 5.dp),
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        terminals.forEach { terminal ->
            var menuVisible by remember(terminal.id) { mutableStateOf(false) }
            val selected = terminal.id == selectedId
            Surface(
                color = if (selected) NauclioSurfaceHigh else NauclioSurface,
                border = BorderStroke(1.dp, if (selected) NauclioAegean.copy(alpha = 0.55f) else NauclioOutline),
                shape = RoundedCornerShape(13.dp),
                modifier = Modifier.widthIn(min = 126.dp, max = 210.dp).height(48.dp)
                    .clickable { onSelect(terminal.id) }
                    .testTag("terminal-tab-${terminal.id}"),
            ) {
                Row(Modifier.padding(start = 11.dp, end = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        Modifier.size(7.dp).background(
                            if (terminal.status == "running") NauclioSeafoam else NauclioCoral,
                            CircleShape,
                        ),
                    )
                    Spacer(Modifier.width(8.dp))
                    Column(Modifier.weight(1f)) {
                        Text(terminal.name, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(
                            "${terminal.columns}×${terminal.rows} · ${terminal.shell}",
                            color = NauclioMuted,
                            fontSize = 9.sp,
                            fontFamily = FontFamily.Monospace,
                            maxLines = 1,
                        )
                    }
                    Box {
                        IconButton(onClick = { menuVisible = true }, modifier = Modifier.size(34.dp)) {
                            Icon(Icons.Outlined.MoreVert, "Actions for ${terminal.name}", tint = NauclioMuted, modifier = Modifier.size(18.dp))
                        }
                        DropdownMenu(expanded = menuVisible, onDismissRequest = { menuVisible = false }) {
                            DropdownMenuItem(
                                text = { Text("Rename") },
                                leadingIcon = { Icon(Icons.Outlined.Edit, null) },
                                onClick = { menuVisible = false; onRename(terminal) },
                            )
                            DropdownMenuItem(
                                text = { Text("Close terminal", color = NauclioCoral) },
                                leadingIcon = { Icon(Icons.Outlined.Close, null, tint = NauclioCoral) },
                                onClick = { menuVisible = false; onClose(terminal) },
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun TerminalEmptyState(loading: Boolean, hasProjects: Boolean, onCreate: () -> Unit) {
    Box(Modifier.fillMaxSize().padding(30.dp), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Surface(color = NauclioSurfaceHigh, shape = RoundedCornerShape(24.dp), modifier = Modifier.size(82.dp)) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(Icons.Outlined.Keyboard, null, tint = NauclioAegean, modifier = Modifier.size(38.dp))
                }
            }
            Text(if (loading) "Finding your terminals…" else "A shell that stays put", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Text(
                if (hasProjects) "Start a native terminal on your Mac. The daemon keeps it alive when this app sleeps, disconnects, or restarts."
                else "Add a project before starting a persistent terminal.",
                color = NauclioMuted,
                fontSize = 13.sp,
                lineHeight = 19.sp,
                modifier = Modifier.widthIn(max = 340.dp),
            )
            Button(onClick = onCreate, enabled = hasProjects && !loading, modifier = Modifier.testTag("empty-new-terminal")) {
                Icon(Icons.Default.Add, null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(7.dp))
                Text("New terminal")
            }
        }
    }
}

@Composable
private fun TerminalAccessoryBar(
    enabled: Boolean,
    controlArmed: Boolean,
    onControl: () -> Unit,
    onKey: (Int) -> Unit,
    onBytes: (ByteArray) -> Unit,
    onPaste: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().height(46.dp).background(TerminalBar).horizontalScroll(rememberScrollState())
            .padding(horizontal = 7.dp, vertical = 5.dp),
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TerminalKey("esc", enabled) { onBytes(byteArrayOf(0x1b)) }
        TerminalKey("ctrl", enabled, selected = controlArmed, onClick = onControl)
        TerminalKey("tab", enabled) { onKey(KeyEvent.KEYCODE_TAB) }
        TerminalKey("←", enabled) { onKey(KeyEvent.KEYCODE_DPAD_LEFT) }
        TerminalKey("↓", enabled) { onKey(KeyEvent.KEYCODE_DPAD_DOWN) }
        TerminalKey("↑", enabled) { onKey(KeyEvent.KEYCODE_DPAD_UP) }
        TerminalKey("→", enabled) { onKey(KeyEvent.KEYCODE_DPAD_RIGHT) }
        TerminalKey("paste", enabled, onClick = onPaste)
    }
}

@Composable
private fun TerminalKey(label: String, enabled: Boolean, selected: Boolean = false, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        enabled = enabled,
        color = if (selected) NauclioAegean.copy(alpha = 0.28f) else NauclioSurfaceHigh,
        contentColor = if (selected) NauclioText else NauclioMuted,
        border = BorderStroke(1.dp, if (selected) NauclioAegean.copy(alpha = 0.62f) else NauclioOutline),
        shape = RoundedCornerShape(8.dp),
        modifier = Modifier.height(34.dp).widthIn(min = 42.dp).testTag("terminal-key-$label"),
    ) {
        Box(Modifier.padding(horizontal = 10.dp), contentAlignment = Alignment.Center) {
            Text(label, fontFamily = FontFamily.Monospace, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun TerminalStatusBar(terminal: Terminal, project: Project?, hostname: String, connected: Boolean) {
    Row(
        Modifier.fillMaxWidth().height(31.dp).background(TerminalBar).padding(horizontal = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(6.dp).background(if (connected) NauclioSeafoam else NauclioMuted, CircleShape))
        Spacer(Modifier.width(7.dp))
        Text(
            listOfNotNull(hostname.takeIf(String::isNotBlank), project?.name).joinToString(" · ").ifBlank { "remote Mac" },
            color = NauclioMuted,
            fontSize = 9.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
        )
        Text("  ${terminal.workingDirectory}", color = NauclioMuted.copy(alpha = 0.72f), fontSize = 9.sp, fontFamily = FontFamily.Monospace, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        Text("${terminal.columns}×${terminal.rows}", color = NauclioMuted, fontSize = 9.sp, fontFamily = FontFamily.Monospace)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NewTerminalSheet(state: NauclioUiState, model: NauclioViewModel) {
    val initialProject = state.projects.firstOrNull { it.id == state.selectedProjectId } ?: state.projects.firstOrNull()
    var projectId by remember(state.terminalCreateVisible) { mutableStateOf(initialProject?.id.orEmpty()) }
    var name by remember(state.terminalCreateVisible) { mutableStateOf("android") }
    var shell by remember(state.terminalCreateVisible) { mutableStateOf("zsh") }
    var workingDirectory by remember(state.terminalCreateVisible) { mutableStateOf(initialProject?.path.orEmpty()) }
    var projectMenuVisible by remember { mutableStateOf(false) }
    val project = state.projects.firstOrNull { it.id == projectId }

    LaunchedEffect(projectId) {
        project?.let { workingDirectory = it.path }
    }
    ModalBottomSheet(
        onDismissRequest = model::dismissTerminalCreate,
        containerColor = NauclioSurface,
    ) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).imePadding().navigationBarsPadding()
                .padding(start = 18.dp, end = 18.dp, bottom = 22.dp),
            verticalArrangement = Arrangement.spacedBy(13.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Surface(color = NauclioAegean.copy(alpha = 0.14f), shape = RoundedCornerShape(14.dp), modifier = Modifier.size(48.dp)) {
                    Box(contentAlignment = Alignment.Center) { Icon(Icons.Outlined.Terminal, null, tint = NauclioAegean) }
                }
                Spacer(Modifier.width(12.dp))
                Column {
                    Text("New terminal", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                    Text("Persistent on the daemon, streamed to Android", color = NauclioMuted, fontSize = 11.sp)
                }
            }
            Box {
                OutlinedButton(
                    onClick = { projectMenuVisible = true },
                    modifier = Modifier.fillMaxWidth().height(56.dp).testTag("terminal-project-picker"),
                    contentPadding = PaddingValues(horizontal = 14.dp),
                ) {
                    Column(Modifier.weight(1f), horizontalAlignment = Alignment.Start) {
                        Text(project?.name ?: "Choose project", color = NauclioText, fontWeight = FontWeight.SemiBold)
                        Text(project?.path.orEmpty(), color = NauclioMuted, fontFamily = FontFamily.Monospace, fontSize = 10.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
                DropdownMenu(expanded = projectMenuVisible, onDismissRequest = { projectMenuVisible = false }) {
                    state.projects.forEach { candidate ->
                        DropdownMenuItem(
                            text = {
                                Column {
                                    Text(candidate.name)
                                    Text(candidate.path, color = NauclioMuted, fontFamily = FontFamily.Monospace, fontSize = 10.sp, maxLines = 1)
                                }
                            },
                            onClick = { projectId = candidate.id; projectMenuVisible = false },
                        )
                    }
                }
            }
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("Session name") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().testTag("terminal-name"),
            )
            OutlinedTextField(
                value = workingDirectory,
                onValueChange = { workingDirectory = it },
                label = { Text("Start in") },
                supportingText = { Text("Must be inside the selected project") },
                singleLine = true,
                textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
                modifier = Modifier.fillMaxWidth().testTag("terminal-working-directory"),
            )
            Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
                Text("Shell", color = NauclioMuted, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    listOf("zsh", "bash", "fish", "sh").forEach { candidate ->
                        FilterChip(
                            selected = shell == candidate,
                            onClick = { shell = candidate },
                            label = { Text(candidate, fontFamily = FontFamily.Monospace) },
                            modifier = Modifier.testTag("terminal-shell-$candidate"),
                        )
                    }
                }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedButton(onClick = model::dismissTerminalCreate, modifier = Modifier.weight(1f)) { Text("Cancel") }
                Button(
                    onClick = { model.createTerminal(projectId, name, shell, workingDirectory) },
                    enabled = projectId.isNotBlank() && name.isNotBlank() && workingDirectory.isNotBlank() && !state.terminalLoading,
                    modifier = Modifier.weight(1f).testTag("create-terminal"),
                ) { Text(if (state.terminalLoading) "Starting…" else "Start terminal") }
            }
        }
    }
}

@Composable
private fun RenameTerminalDialog(terminal: Terminal, onDismiss: () -> Unit, onRename: (String) -> Unit) {
    var name by remember(terminal.id) { mutableStateOf(terminal.name) }
    AlertDialog(
        onDismissRequest = onDismiss,
        icon = { Icon(Icons.Outlined.Edit, null) },
        title = { Text("Rename terminal") },
        text = {
            OutlinedTextField(value = name, onValueChange = { name = it }, singleLine = true, label = { Text("Session name") })
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        confirmButton = { TextButton(onClick = { onRename(name) }, enabled = name.isNotBlank()) { Text("Rename") } },
    )
}
