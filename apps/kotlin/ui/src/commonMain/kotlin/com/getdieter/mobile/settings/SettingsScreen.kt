@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.getdieter.mobile.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.*
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.platform.*
import com.getdieter.mobile.store.*

@Composable
internal fun SettingsScreen(store: MobileStore) {
    val session by store.session.slice.collectAsState()
    val selectedPalette by store.theme.palette.collectAsState()
    val appearance by store.theme.appearance.collectAsState()
    val dynamic by store.theme.dynamicColor.collectAsState()
    val outbox by store.workspace.outbox.collectAsState()
    val channels by store.channels.settings.collectAsState()
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
                        { store.theme.setAppearance(modes[it].first) },
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
                            DSwitch(dynamic, store.theme::setDynamicColor)
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
                                    store.theme.setPalette(item)
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
            item("experimental") {
                SectionHeader("Experimental")
                ListRow(
                    "Agent channels",
                    position = Position.SINGLE,
                    subtitle =
                        "Agents of a project, on all your machines, message each other and claim " +
                            "the files they change. Applies to every machine.",
                    glyph = Glyph.TAG,
                    tile = Color(0xFF0A84FF),
                    subtitleMaxLines = 3,
                    trailing = {
                        DSwitch(
                            channels.global,
                            store.channels::setEnabled,
                            Modifier.testTag("settings-channels"),
                            enabled = !channels.saving,
                        )
                    },
                )
                if (channels.error.isNotEmpty()) SectionFooter(channels.error)
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
                                    else store.session.retry()
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
    if (signOut) SignOutDialog(store) { signOut = false }
}

@Composable
internal fun SignOutDialog(store: MobileStore, onDismiss: () -> Unit) {
    ConfirmDialog(
        "Sign out of Dieter?",
        "This clears this device’s cached workspace, unsent work and drafts for this account.",
        "Sign out",
        {
            store.command(Command(sign_out = SignOut()))
            onDismiss()
        },
        onDismiss,
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
