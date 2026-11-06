@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.getdieter.mobile.tools

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.*
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.design.Tone
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.platform.*
import com.getdieter.mobile.store.*

@Composable
internal fun TerminalsScreen(store: MobileStore, inConversation: Boolean = false) {
    val view by store.terminals.overview.collectAsState()
    val local by store.terminals.card.collectAsState()
    val conversation by store.conversation.slice.collectAsState()
    var create by remember { mutableStateOf(false) }
    val cardId = if (inConversation) store.conversation.selectedCard.value else ""
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
            // Every machine's shells, each under its machine; a conversation's are one group.
            val groups =
                if (inConversation) listOf("" to entries)
                else entries.groupBy { it.machine_name }.toList()
            groups.forEach { (machineName, group) ->
                if (machineName.isNotEmpty())
                    item(key = "machine-$machineName") { SectionHeader(machineName) }
                itemsIndexed(group, key = { _, entry -> entry.id }) { index, entry ->
                    ListRow(
                        entry.terminal?.name.orEmpty().ifEmpty { "Terminal" },
                        Modifier.testTag("terminal-${entry.id}"),
                        position = Position.of(index, group.size),
                        subtitle = entry.row?.status?.ifEmpty { null },
                        glyph = Glyph.TERMINAL,
                        tile = Color(0xFF3A3A3C),
                        accessory = Accessory.CHEVRON,
                        onClick = { store.push(MobileRoute.TerminalSession(entry.id, cardId)) },
                    )
                }
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
    val view by store.terminals.overview.collectAsState()
    val local by store.terminals.card.collectAsState()
    val selected by store.terminals.visible.collectAsState()
    val acceptsInput by store.terminals.acceptsInput.collectAsState()
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
    val shellId = entry?.terminal?.id ?: terminalId
    fun send(value: TerminalsCommand) = store.terminals.command(value, inCard = cardId.isNotEmpty())
    DisposableEffect(store, cardId) {
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
                send(TerminalsCommand(rename = TerminalRename(shellId, it)))
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
                send(TerminalsCommand(close = TerminalId(shellId)))
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
                "esc" to { store.terminals.keys.tryEmit(TerminalKey.TERMINAL_KEY_ESCAPE) },
                "tab" to { store.terminals.keys.tryEmit(TerminalKey.TERMINAL_KEY_TAB) },
                "ctrl C" to
                    {
                        store.terminals.input(byteArrayOf(3))
                        true
                    },
                "↑" to { store.terminals.keys.tryEmit(TerminalKey.TERMINAL_KEY_UP) },
                "↓" to { store.terminals.keys.tryEmit(TerminalKey.TERMINAL_KEY_DOWN) },
                "←" to { store.terminals.keys.tryEmit(TerminalKey.TERMINAL_KEY_LEFT) },
                "→" to { store.terminals.keys.tryEmit(TerminalKey.TERMINAL_KEY_RIGHT) },
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

@Composable
internal fun TerminalEditor(store: MobileStore, machineId: String = "", onDismiss: () -> Unit) {
    val session by store.session.slice.collectAsState()
    val workspace by store.workspace.slice.collectAsState()
    val busy by store.busy.collectAsState()
    // From a machine's page the terminal starts there; otherwise on the first available machine.
    var machine by remember {
        mutableStateOf(
            machineId.ifEmpty { session.machines.firstOrNull { it.available }?.id.orEmpty() }
        )
    }
    var checkout by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    var shell by remember { mutableStateOf("") }
    val checkouts =
        workspace.projects.flatMap { project ->
            project.checkouts.filter { it.daemon_id == machine }.map { it to project }
        }
    Sheet(
        "New Terminal",
        onDismiss,
        confirm =
            ChromeAction(
                "create-terminal",
                "Create",
                Glyph.CHECK,
                enabled = machine.isNotEmpty() && !busy,
            ) {
                store.action {
                    val project = checkouts.firstOrNull { it.first.id == checkout }?.second
                    store.core.dispatch(
                        Command(
                            terminal_overview =
                                TerminalOverviewCommand(
                                    scope = MobileStore.TERMINAL_OVERVIEW_SCOPE,
                                    create =
                                        CreateOverviewTerminal(
                                            daemon_id = machine,
                                            machine_home = checkout.isEmpty(),
                                            project_id = project?.id.orEmpty(),
                                            checkout_id = checkout,
                                            name = name,
                                            shell = shell,
                                        ),
                                )
                        )
                    )
                    onDismiss()
                }
            },
    ) {
        val machines = session.machines.filter { it.available }
        Group(listOf(0, 1)) { index, position ->
            if (index == 0)
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
                    checkout = ""
                }
            else
                PickerRow(
                    "Directory",
                    checkouts
                        .firstOrNull { it.first.id == checkout }
                        ?.let { it.second.name + " · " + it.first.name } ?: "Home folder",
                    listOf("" to "Home folder") +
                        checkouts.map { it.first.id to (it.second.name + " · " + it.first.name) },
                    checkout,
                    machine.isNotEmpty(),
                    position,
                    Glyph.FOLDER,
                ) {
                    checkout = it
                }
        }
        Spacer(Modifier.height(16.dp))
        FormColumn {
            MobileTextField(
                name,
                { name = it },
                Modifier.fillMaxWidth().testTag("terminal-name"),
                label = { Text("Name") },
                placeholder = { Text("Terminal name (optional)") },
                singleLine = true,
            )
            MobileTextField(
                shell,
                { shell = it },
                Modifier.fillMaxWidth(),
                label = { Text("Shell") },
                placeholder = { Text("Shell (machine default)") },
                singleLine = true,
            )
        }
    }
}
