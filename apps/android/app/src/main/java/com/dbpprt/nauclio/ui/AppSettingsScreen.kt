@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.nauclio.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.ArrowDownward
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.DragIndicator
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.ViewKanban
import androidx.compose.material.icons.outlined.Wifi
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.PrimaryTabRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.dbpprt.nauclio.connection.ConnectionPhase
import com.dbpprt.nauclio.connection.isLoopbackHost
import com.dbpprt.nauclio.data.NAUCLIO_ENDPOINTS
import com.dbpprt.nauclio.data.NauclioEndpoint
import com.dbpprt.nauclio.data.nauclioEndpointFromAddress
import com.dbpprt.nauclio.settings.NavigationStyle
import com.dbpprt.nauclio.update.AppUpdateManager
import com.dbpprt.nauclio.update.AppUpdateState
import com.dbpprt.nauclio.ui.theme.NauclioDivider
import com.dbpprt.nauclio.ui.theme.NauclioSeafoam
import com.dbpprt.nauclio.ui.theme.NauclioAegean
import com.dbpprt.nauclio.ui.theme.NauclioMuted
import com.dbpprt.nauclio.ui.theme.NauclioOutline
import com.dbpprt.nauclio.ui.theme.NauclioSurface
import com.dbpprt.nauclio.ui.theme.NauclioSurfaceHigh
import com.dbpprt.nauclio.ui.theme.NauclioText

private const val CONNECTIONS_TAB = 0
private const val DISPLAY_TAB = 1
private const val UPDATES_TAB = 2

private data class ConnectionDraft(val id: String, val label: String, val address: String)

@Composable
fun AppSettingsScreen(
    state: NauclioUiState,
    model: NauclioViewModel,
    updateManager: AppUpdateManager,
    contentPadding: PaddingValues,
) {
    val endpointKey = state.configuredConnections.joinToString("|") { "${it.id}:${it.label}:${it.address}" }
    var drafts by remember(endpointKey) {
        mutableStateOf(
            state.configuredConnections.distinctBy { it.address }.map { endpoint ->
                ConnectionDraft(endpoint.id, endpoint.label, endpoint.address)
            },
        )
    }
    var activeDraftId by remember(endpointKey, state.activeGatewayId) {
        mutableStateOf(state.activeGatewayId.takeIf { active -> drafts.any { it.id == active } } ?: drafts.firstOrNull()?.id.orEmpty())
    }
    var selectedTab by remember { mutableIntStateOf(CONNECTIONS_TAB) }
    var confirmation by remember { mutableStateOf<String?>(null) }
    val parsed = drafts.map { draft ->
        runCatching { nauclioEndpointFromAddress(draft.id, draft.label, draft.address) }
    }
    val validationError = when {
        drafts.isEmpty() -> "Keep at least one connection."
        parsed.any { it.isFailure } -> parsed.first { it.isFailure }.exceptionOrNull()?.message
        parsed.mapNotNull { it.getOrNull() }.any { !it.secure && !isLoopbackHost(it.host) } -> "Remote gateways must use HTTPS."
        parsed.mapNotNull { it.getOrNull()?.address?.lowercase() }.distinct().size != drafts.size -> "Connection addresses must be unique."
        else -> null
    }

    Column(
        Modifier.fillMaxSize().padding(contentPadding).testTag("app-settings"),
    ) {
        SettingsHeader(onBack = model::closeSurface)
        PrimaryTabRow(
            selectedTabIndex = selectedTab,
            containerColor = MaterialTheme.colorScheme.background,
            contentColor = NauclioAegean,
        ) {
            SettingsTab("Connections", selectedTab == CONNECTIONS_TAB) { selectedTab = CONNECTIONS_TAB }
            SettingsTab("Display", selectedTab == DISPLAY_TAB) { selectedTab = DISPLAY_TAB }
            SettingsTab("Updates", selectedTab == UPDATES_TAB) { selectedTab = UPDATES_TAB }
        }
        SurfaceErrorBanner(state.error, model::clearError)
        Box(Modifier.weight(1f)) {
            when (selectedTab) {
                CONNECTIONS_TAB -> ConnectionsSettings(
                    state = state,
                    model = model,
                    drafts = drafts,
                    validationError = validationError,
                    confirmation = confirmation,
                    activeGatewayId = activeDraftId,
                    onSelectGateway = { activeDraftId = it },
                    onDraftsChanged = {
                        drafts = it
                        confirmation = null
                    },
                )
                DISPLAY_TAB -> DisplaySettings(state, model)
                else -> UpdateSettings(updateManager)
            }
        }
        if (selectedTab == CONNECTIONS_TAB) {
            SettingsActionBar(
                validationError = validationError,
                onDefaults = {
                    drafts = NAUCLIO_ENDPOINTS.map { ConnectionDraft(it.id, it.label, it.address) }
                    activeDraftId = NAUCLIO_ENDPOINTS.first().id
                    model.resetConnectionTargets()
                    confirmation = "Default connections restored."
                },
                onSave = {
                    val endpoints: List<NauclioEndpoint> = parsed.mapNotNull { it.getOrNull() }
                    val activeGatewayId = activeDraftId.takeIf { active -> endpoints.any { it.id == active } }
                        ?: endpoints.first().id
                    model.updateConnectionTargets(endpoints, activeGatewayId)
                    confirmation = if (state.desiredConnected) {
                        "Saved. Reconnecting to the active gateway."
                    } else {
                        "Connections saved."
                    }
                },
            )
        }
    }
}

@Composable
private fun SettingsHeader(onBack: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().height(72.dp).padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onBack, modifier = Modifier.size(48.dp)) {
            Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Back")
        }
        Spacer(Modifier.width(8.dp))
        Text("Settings", style = MaterialTheme.typography.headlineMedium)
    }
}

@Composable
private fun SettingsTab(label: String, selected: Boolean, onClick: () -> Unit) {
    Tab(
        selected = selected,
        onClick = onClick,
        modifier = Modifier.height(52.dp).testTag("settings-${label.lowercase()}"),
        text = {
            Text(
                label,
                color = if (selected) NauclioAegean else NauclioMuted,
                fontWeight = FontWeight.SemiBold,
                fontSize = 16.sp,
            )
        },
    )
}

@Composable
private fun ConnectionsSettings(
    state: NauclioUiState,
    model: NauclioViewModel,
    drafts: List<ConnectionDraft>,
    validationError: String?,
    confirmation: String?,
    activeGatewayId: String,
    onSelectGateway: (String) -> Unit,
    onDraftsChanged: (List<ConnectionDraft>) -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize().testTag("settings-connections-content"),
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 18.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            Text(
                "Sign in once at a gateway. Nauclio shows projects from every enrolled machine and routes each action automatically, preferring verified direct TLS before its encrypted relay.",
                color = NauclioMuted,
                fontSize = 14.sp,
                lineHeight = 20.sp,
            )
        }
        item { ConnectionStatusCard(state, model) }
        item {
            Text(
                "Gateway connections",
                color = NauclioAegean,
                fontSize = 18.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
        drafts.forEachIndexed { index, draft ->
            item(key = draft.id) {
                ConnectionEditorCard(
                    draft = draft,
                    index = index,
                    count = drafts.size,
                    active = draft.id == activeGatewayId,
                    onSelect = { onSelectGateway(draft.id) },
                    onChange = { updated ->
                        onDraftsChanged(drafts.toMutableList().also { it[index] = updated })
                    },
                    onMoveUp = {
                        if (index > 0) {
                            onDraftsChanged(drafts.toMutableList().also { list ->
                                val item = list.removeAt(index)
                                list.add(index - 1, item)
                            })
                        }
                    },
                    onMoveDown = {
                        if (index < drafts.lastIndex) {
                            onDraftsChanged(drafts.toMutableList().also { list ->
                                val item = list.removeAt(index)
                                list.add(index + 1, item)
                            })
                        }
                    },
                    onDelete = { onDraftsChanged(drafts.filterIndexed { itemIndex, _ -> itemIndex != index }) },
                )
            }
        }
        item {
            Surface(
                onClick = {
                    onDraftsChanged(
                        drafts + ConnectionDraft(
                            id = "custom_${System.nanoTime()}",
                            label = "New connection",
                            address = "",
                        ),
                    )
                },
                color = NauclioSurface,
                shape = RoundedCornerShape(20.dp),
                modifier = Modifier.fillMaxWidth().testTag("add-connection"),
            ) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 18.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Default.Add, contentDescription = null, tint = NauclioAegean)
                    Spacer(Modifier.width(12.dp))
                    Text("Add connection", color = NauclioAegean, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                }
            }
        }
        if (validationError != null) {
            item { Text(validationError, color = MaterialTheme.colorScheme.error, fontSize = 12.sp) }
        } else if (confirmation != null) {
            item { Text(confirmation, color = NauclioSeafoam, fontSize = 12.sp) }
        }
    }
}

@Composable
private fun SettingsActionBar(
    validationError: String?,
    onDefaults: () -> Unit,
    onSave: () -> Unit,
) {
    Surface(color = MaterialTheme.colorScheme.background, tonalElevation = 0.dp) {
        Column {
            HorizontalDivider(color = NauclioDivider)
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TextButton(onClick = onDefaults, modifier = Modifier.weight(0.72f).height(52.dp)) {
                    Text("↻", color = NauclioAegean, fontSize = 22.sp)
                    Spacer(Modifier.width(8.dp))
                    Text("Defaults")
                }
                Button(
                    onClick = onSave,
                    enabled = validationError == null,
                    modifier = Modifier.weight(1.45f).height(52.dp).testTag("save-connections"),
                ) {
                    Text("Save connections", fontSize = 16.sp)
                }
            }
        }
    }
}

@Composable
private fun ConnectionStatusCard(state: NauclioUiState, model: NauclioViewModel) {
    val connected = state.connectionPhase == ConnectionPhase.CONNECTED
    Surface(
        onClick = model::showConnectionDialog,
        color = if (connected) Color(0xFF0B2D32) else NauclioSurface,
        shape = RoundedCornerShape(24.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            Modifier.padding(horizontal = 14.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Surface(
                shape = CircleShape,
                color = if (connected) NauclioSeafoam.copy(alpha = 0.13f) else NauclioSurfaceHigh,
                modifier = Modifier.size(48.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(Icons.Outlined.Wifi, null, tint = if (connected) NauclioSeafoam else NauclioMuted, modifier = Modifier.size(22.dp))
                }
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(if (connected) "Connected" else "Connection status", fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
                Text(
                    state.endpoint,
                    color = if (connected) NauclioSeafoam.copy(alpha = 0.76f) else NauclioMuted,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 12.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Surface(
                color = if (connected) NauclioSeafoam.copy(alpha = 0.15f) else NauclioSurfaceHigh,
                shape = RoundedCornerShape(22.dp),
            ) {
                Text(
                    "View status",
                    color = if (connected) NauclioSeafoam else NauclioAegean,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                )
            }
        }
    }
}

@Composable
private fun ConnectionEditorCard(
    draft: ConnectionDraft,
    index: Int,
    count: Int,
    active: Boolean,
    onSelect: () -> Unit,
    onChange: (ConnectionDraft) -> Unit,
    onMoveUp: () -> Unit,
    onMoveDown: () -> Unit,
    onDelete: () -> Unit,
) {
    Surface(
        color = NauclioSurface,
        shape = RoundedCornerShape(20.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column {
            Row(
                Modifier.fillMaxWidth().padding(start = 12.dp, end = 8.dp, top = 8.dp, bottom = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Outlined.DragIndicator, contentDescription = null, tint = NauclioMuted, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(8.dp))
                Column(Modifier.weight(1f)) {
                    Text(draft.label.ifBlank { "Gateway ${index + 1}" }, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                    Text(if (active) "Active gateway" else "Separate deployment", color = if (active) NauclioSeafoam else NauclioMuted, fontSize = 11.sp)
                }
                if (!active) {
                    TextButton(onClick = onSelect) { Text("Use") }
                }
                IconButton(onClick = onMoveUp, enabled = index > 0, modifier = Modifier.size(36.dp)) {
                    Icon(Icons.Outlined.ArrowUpward, "Move connection up", modifier = Modifier.size(18.dp))
                }
                IconButton(onClick = onMoveDown, enabled = index < count - 1, modifier = Modifier.size(36.dp)) {
                    Icon(Icons.Outlined.ArrowDownward, "Move connection down", modifier = Modifier.size(18.dp))
                }
                IconButton(onClick = onDelete, enabled = count > 1, modifier = Modifier.size(36.dp)) {
                    Icon(Icons.Outlined.DeleteOutline, "Delete connection", modifier = Modifier.size(18.dp))
                }
            }
            Column(
                Modifier.padding(start = 12.dp, end = 12.dp, bottom = 12.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                ConnectionTextField(
                    value = draft.label,
                    onValueChange = { onChange(draft.copy(label = it)) },
                    label = "Name",
                    modifier = Modifier.testTag("connection-name-${draft.id}"),
                )
                ConnectionTextField(
                    value = draft.address,
                    onValueChange = { onChange(draft.copy(address = it)) },
                    label = "Host and port",
                    supportingText = "Use https:// for public Nauclio servers; loopback may use http://",
                    modifier = Modifier.testTag("connection-address-${draft.id}"),
                )
            }
        }
    }
}

@Composable
private fun ConnectionTextField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    modifier: Modifier = Modifier,
    supportingText: String? = null,
) {
    TextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        supportingText = supportingText?.let { value -> ({ Text(value, color = NauclioMuted, fontSize = 11.sp) }) },
        singleLine = true,
        shape = RoundedCornerShape(12.dp),
        colors = TextFieldDefaults.colors(
            focusedContainerColor = NauclioSurfaceHigh,
            unfocusedContainerColor = NauclioSurfaceHigh,
            disabledContainerColor = NauclioSurfaceHigh,
            focusedTextColor = NauclioText,
            unfocusedTextColor = NauclioText,
            focusedIndicatorColor = NauclioAegean,
            unfocusedIndicatorColor = NauclioOutline,
            focusedLabelColor = NauclioAegean,
            unfocusedLabelColor = NauclioMuted,
        ),
        modifier = modifier.fillMaxWidth(),
    )
}

@Composable
private fun DisplaySettings(state: NauclioUiState, model: NauclioViewModel) {
    LazyColumn(
        modifier = Modifier.fillMaxSize().testTag("settings-display-content"),
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 18.dp, bottom = 36.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item {
            SettingsSectionHeader(
                title = "Visual settings",
                subtitle = "Choose how the primary app destinations are presented.",
            )
        }
        item {
            GlassNavigationSetting(state.navigationStyle == NavigationStyle.GLASS) { enabled ->
                model.setNavigationStyle(if (enabled) NavigationStyle.GLASS else NavigationStyle.CLASSIC)
            }
        }
        item { Spacer(Modifier.height(4.dp)) }
        item {
            SettingsSectionHeader(
                title = "Chat display",
                subtitle = "Control optional diagnostic content across standalone and board conversations.",
            )
        }
        item {
            ReasoningTraceSetting(
                enabled = state.showReasoningTraces,
                onToggle = model::setShowReasoningTraces,
            )
        }
    }
}

@Composable
private fun SettingsSectionHeader(title: String, subtitle: String) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(title, color = NauclioAegean, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
        Text(subtitle, color = NauclioMuted, fontSize = 14.sp, lineHeight = 20.sp)
    }
}

@Composable
private fun UpdateSettings(manager: AppUpdateManager) {
    val state by manager.state.collectAsStateWithLifecycle()
    val busy = state is AppUpdateState.Checking || state is AppUpdateState.Downloading
    val status = when (val current = state) {
        AppUpdateState.Idle -> if (manager.automaticChecksEnabled) {
            "Checks automatically when Nauclio starts."
        } else {
            "Use Check now in development builds."
        }
        AppUpdateState.Checking -> "Checking GitHub…"
        is AppUpdateState.UpToDate -> "${current.version} is current."
        is AppUpdateState.Available -> "${current.release.version} is available."
        is AppUpdateState.Downloading -> {
            val percent = ((current.bytesDownloaded * 100) / current.release.sizeBytes).coerceIn(0, 100)
            "Downloading ${current.release.version} · $percent%"
        }
        is AppUpdateState.ReadyToInstall -> "${current.release.version} is downloaded and verified."
        is AppUpdateState.Failed -> current.message
    }
    val hasPrompt = when (state) {
        is AppUpdateState.Available,
        is AppUpdateState.ReadyToInstall,
        is AppUpdateState.Failed,
        -> true
        else -> false
    }

    LazyColumn(
        modifier = Modifier.fillMaxSize().testTag("settings-updates-content"),
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 18.dp, bottom = 36.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item {
            SettingsSectionHeader(
                title = "App updates",
                subtitle = "Checks the official dbpprt/nauclio GitHub releases and verifies the APK checksum before install.",
            )
        }
        item {
            Surface(color = NauclioSurface, shape = RoundedCornerShape(20.dp), modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Nauclio ${manager.currentVersion}", fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
                    Text(
                        status,
                        color = if (state is AppUpdateState.Failed) MaterialTheme.colorScheme.error else NauclioMuted,
                        fontSize = 14.sp,
                        lineHeight = 20.sp,
                    )
                    Button(
                        onClick = {
                            if (hasPrompt) manager.showPrompt()
                            else manager.checkForUpdates(force = true, showErrors = true)
                        },
                        enabled = !busy,
                        modifier = Modifier.fillMaxWidth().height(50.dp).testTag("check-app-update"),
                    ) {
                        if (busy) {
                            CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                            Spacer(Modifier.width(8.dp))
                        }
                        Text(
                            when {
                                state is AppUpdateState.Checking -> "Checking…"
                                state is AppUpdateState.Downloading -> "Downloading…"
                                hasPrompt -> "View update"
                                else -> "Check now"
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun GlassNavigationSetting(enabled: Boolean, onToggle: (Boolean) -> Unit) {
    Surface(color = NauclioSurface, shape = RoundedCornerShape(20.dp), modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Glass lens navigation", fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
                    Text(
                        "Floating translucent dock, raised active lens, and balanced navigation slots.",
                        color = NauclioMuted,
                        fontSize = 14.sp,
                        lineHeight = 20.sp,
                    )
                }
                Spacer(Modifier.width(12.dp))
                Switch(
                    checked = enabled,
                    onCheckedChange = onToggle,
                    modifier = Modifier.semantics { contentDescription = "Glass lens navigation" }
                        .testTag("glass-navigation-toggle"),
                )
            }
            GlassNavigationPreview()
            Text(
                if (enabled) "Glass navigation is active." else "Classic navigation remains the default.",
                color = if (enabled) NauclioSeafoam else NauclioMuted,
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
            )
        }
    }
}

@Composable
private fun ReasoningTraceSetting(enabled: Boolean, onToggle: (Boolean) -> Unit) {
    Surface(color = NauclioSurface, shape = RoundedCornerShape(20.dp), modifier = Modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text("Reasoning traces", fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
                Text(
                    "Hidden by default. Enable this only when you want to inspect model reasoning entries in chats.",
                    color = NauclioMuted,
                    fontSize = 14.sp,
                    lineHeight = 20.sp,
                )
            }
            Spacer(Modifier.width(12.dp))
            Switch(
                checked = enabled,
                onCheckedChange = onToggle,
                modifier = Modifier.semantics { contentDescription = "Show reasoning traces" }
                    .testTag("reasoning-traces-toggle"),
            )
        }
    }
}

@Composable
private fun GlassNavigationPreview() {
    Box(
        Modifier.fillMaxWidth().height(118.dp).clip(RoundedCornerShape(18.dp))
            .background(Color(0xFF050B14)),
        contentAlignment = Alignment.Center,
    ) {
        Surface(
            color = Color(0xE60B1628),
            border = BorderStroke(1.dp, NauclioOutline),
            shape = RoundedCornerShape(30.dp),
            modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp).height(64.dp),
        ) {
            Row(
                Modifier.fillMaxSize().padding(horizontal = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                listOf(
                    Icons.Outlined.ChatBubbleOutline,
                    Icons.Outlined.ViewKanban,
                    Icons.Outlined.FolderOpen,
                    Icons.Outlined.CalendarMonth,
                    Icons.Outlined.Settings,
                ).forEachIndexed { index, icon ->
                    Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                        if (index == 1) {
                            Box(
                                Modifier.size(54.dp).clip(CircleShape).background(NauclioAegean)
                                    .border(1.dp, Color.White.copy(alpha = 0.35f), CircleShape),
                                contentAlignment = Alignment.Center,
                            ) {
                                Icon(icon, null, tint = Color(0xFF071426), modifier = Modifier.size(25.dp))
                            }
                        } else {
                            Icon(icon, null, tint = NauclioMuted, modifier = Modifier.size(23.dp))
                        }
                    }
                }
            }
        }
    }
}
