@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

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
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
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
import androidx.compose.material3.AlertDialog
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.connection.isLoopbackHost
import com.dbpprt.dieter.data.DIETER_ENDPOINTS
import com.dbpprt.dieter.data.DieterEndpoint
import com.dbpprt.dieter.data.dieterEndpointFromAddress
import com.dbpprt.dieter.settings.NavigationStyle
import com.dbpprt.dieter.settings.DieterPalette
import com.dbpprt.dieter.update.AppUpdateManager
import com.dbpprt.dieter.update.AppUpdateState
import com.dbpprt.dieter.ui.theme.DieterDivider
import com.dbpprt.dieter.ui.theme.DieterEyes
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterOutline
import com.dbpprt.dieter.ui.theme.DieterSurface
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh
import com.dbpprt.dieter.ui.theme.DieterText
import com.dbpprt.dieter.ui.theme.DieterBackground
import com.dbpprt.dieter.ui.theme.DieterEyesTint
import com.dbpprt.dieter.ui.theme.DieterAbyss

private const val CONNECTIONS_TAB = 0
private const val DISPLAY_TAB = 1
private const val UPDATES_TAB = 2

private data class ConnectionDraft(val id: String, val label: String, val address: String)

@Composable
fun AppSettingsScreen(
    state: DieterUiState,
    model: DieterViewModel,
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
    var cleanSyncConfirmation by remember { mutableStateOf(false) }
    val parsed = drafts.map { draft ->
        runCatching { dieterEndpointFromAddress(draft.id, draft.label, draft.address) }
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
            contentColor = DieterShell,
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
                    onCleanSync = { cleanSyncConfirmation = true },
                )
                DISPLAY_TAB -> DisplaySettings(state, model)
                else -> UpdateSettings(updateManager)
            }
        }
        if (selectedTab == CONNECTIONS_TAB) {
            SettingsActionBar(
                validationError = validationError,
                onDefaults = {
                    drafts = DIETER_ENDPOINTS.map { ConnectionDraft(it.id, it.label, it.address) }
                    activeDraftId = DIETER_ENDPOINTS.first().id
                    model.resetConnectionTargets()
                    confirmation = "Default connections restored."
                },
                onSave = {
                    val endpoints: List<DieterEndpoint> = parsed.mapNotNull { it.getOrNull() }
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
    if (cleanSyncConfirmation) {
        AlertDialog(
            onDismissRequest = { cleanSyncConfirmation = false },
            title = { Text("Start a clean sync?") },
            text = {
                Text("Dieter will remove all cached workspace data on this device, keep your sign-in and pending changes, then download fresh snapshots. Content may briefly disappear.")
            },
            confirmButton = {
                Button(
                    onClick = {
                        cleanSyncConfirmation = false
                        confirmation = "Clean sync started."
                        model.cleanSync()
                    },
                    modifier = Modifier.testTag("confirm-clean-sync"),
                ) { Text("Clean sync") }
            },
            dismissButton = {
                TextButton(onClick = { cleanSyncConfirmation = false }) { Text("Cancel") }
            },
        )
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
                color = if (selected) DieterShell else DieterMuted,
                fontWeight = FontWeight.SemiBold,
                fontSize = 16.sp,
            )
        },
    )
}

@Composable
private fun ConnectionsSettings(
    state: DieterUiState,
    model: DieterViewModel,
    drafts: List<ConnectionDraft>,
    validationError: String?,
    confirmation: String?,
    activeGatewayId: String,
    onSelectGateway: (String) -> Unit,
    onDraftsChanged: (List<ConnectionDraft>) -> Unit,
    onCleanSync: () -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize().testTag("settings-connections-content"),
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 18.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            Text(
                "Sign in once at a gateway. Dieter shows projects from every enrolled machine and routes each action automatically, preferring verified direct TLS before its encrypted relay.",
                color = DieterMuted,
                fontSize = 14.sp,
                lineHeight = 20.sp,
            )
        }
        item { ConnectionStatusCard(state, model) }
        item { CleanSyncCard(onCleanSync) }
        item {
            Text(
                "Gateway connections",
                color = DieterShell,
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
                color = DieterSurface,
                shape = RoundedCornerShape(20.dp),
                modifier = Modifier.fillMaxWidth().testTag("add-connection"),
            ) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 18.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Default.Add, contentDescription = null, tint = DieterShell)
                    Spacer(Modifier.width(12.dp))
                    Text("Add connection", color = DieterShell, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                }
            }
        }
        if (validationError != null) {
            item { Text(validationError, color = MaterialTheme.colorScheme.error, fontSize = 12.sp) }
        } else if (confirmation != null) {
            item { Text(confirmation, color = DieterEyes, fontSize = 12.sp) }
        }
    }
}

@Composable
private fun CleanSyncCard(onCleanSync: () -> Unit) {
    Surface(
        color = DieterSurface,
        shape = RoundedCornerShape(20.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text("Complete clean sync", color = DieterText, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                Text(
                    "Discard cached snapshots and cursors, then rebuild from every machine. Sign-in and pending changes are kept.",
                    color = DieterMuted,
                    fontSize = 12.sp,
                    lineHeight = 17.sp,
                )
            }
            Spacer(Modifier.width(12.dp))
            TextButton(onClick = onCleanSync, modifier = Modifier.testTag("clean-sync")) {
                Text("Clean sync", color = DieterShell, fontWeight = FontWeight.SemiBold)
            }
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
            HorizontalDivider(color = DieterDivider)
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TextButton(onClick = onDefaults, modifier = Modifier.weight(0.72f).height(52.dp)) {
                    Text("↻", color = DieterShell, fontSize = 22.sp)
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
private fun ConnectionStatusCard(state: DieterUiState, model: DieterViewModel) {
    val connected = state.connectionPhase == ConnectionPhase.CONNECTED
    Surface(
        onClick = model::showConnectionDialog,
        color = if (connected) DieterEyesTint else DieterSurface,
        shape = RoundedCornerShape(24.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            Modifier.padding(horizontal = 14.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Surface(
                shape = CircleShape,
                color = if (connected) DieterEyes.copy(alpha = 0.13f) else DieterSurfaceHigh,
                modifier = Modifier.size(48.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(Icons.Outlined.Wifi, null, tint = if (connected) DieterEyes else DieterMuted, modifier = Modifier.size(22.dp))
                }
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(if (connected) "Connected" else "Connection status", fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
                Text(
                    state.endpoint,
                    color = if (connected) DieterEyes.copy(alpha = 0.76f) else DieterMuted,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 12.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Surface(
                color = if (connected) DieterEyes.copy(alpha = 0.15f) else DieterSurfaceHigh,
                shape = RoundedCornerShape(22.dp),
            ) {
                Text(
                    "View status",
                    color = if (connected) DieterEyes else DieterShell,
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
        color = DieterSurface,
        shape = RoundedCornerShape(20.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column {
            Row(
                Modifier.fillMaxWidth().padding(start = 12.dp, end = 8.dp, top = 8.dp, bottom = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Outlined.DragIndicator, contentDescription = null, tint = DieterMuted, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(8.dp))
                Column(Modifier.weight(1f)) {
                    Text(draft.label.ifBlank { "Gateway ${index + 1}" }, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                    Text(if (active) "Active gateway" else "Separate deployment", color = if (active) DieterEyes else DieterMuted, fontSize = 11.sp)
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
                    supportingText = "Use https:// for public Dieter servers; loopback may use http://",
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
        supportingText = supportingText?.let { value -> ({ Text(value, color = DieterMuted, fontSize = 11.sp) }) },
        singleLine = true,
        shape = RoundedCornerShape(12.dp),
        colors = TextFieldDefaults.colors(
            focusedContainerColor = DieterSurfaceHigh,
            unfocusedContainerColor = DieterSurfaceHigh,
            disabledContainerColor = DieterSurfaceHigh,
            focusedTextColor = DieterText,
            unfocusedTextColor = DieterText,
            focusedIndicatorColor = DieterShell,
            unfocusedIndicatorColor = DieterOutline,
            focusedLabelColor = DieterShell,
            unfocusedLabelColor = DieterMuted,
        ),
        modifier = modifier.fillMaxWidth(),
    )
}

@Composable
private fun DisplaySettings(state: DieterUiState, model: DieterViewModel) {
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
            PaletteSetting(state.palette, model::setPalette)
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
private fun PaletteSetting(selected: DieterPalette, onSelect: (DieterPalette) -> Unit) {
    Surface(color = DieterSurface, shape = RoundedCornerShape(20.dp), modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text("Palette", fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
                Text(
                    "Changes every app surface, terminal, widget, notification accent, and launcher icon.",
                    color = DieterMuted,
                    fontSize = 14.sp,
                    lineHeight = 20.sp,
                )
            }
            LazyRow(
                contentPadding = PaddingValues(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(9.dp),
            ) {
                items(DieterPalette.entries, key = DieterPalette::slug) { palette ->
                    val active = palette == selected
                    Surface(
                        onClick = { onSelect(palette) },
                        color = if (active) DieterEyesTint else DieterSurfaceHigh,
                        shape = RoundedCornerShape(14.dp),
                        border = BorderStroke(1.dp, if (active) DieterShell else DieterOutline),
                        modifier = Modifier.width(158.dp).height(64.dp)
                            .testTag("palette-${palette.slug}")
                            .semantics {
                                contentDescription = "${palette.displayName} palette${if (active) ", selected" else ""}"
                            },
                    ) {
                        Row(
                            Modifier.padding(horizontal = 11.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(9.dp),
                        ) {
                            Box(
                                Modifier.size(28.dp).clip(CircleShape).background(
                                    Brush.linearGradient(
                                        listOf(
                                            Color(palette.tokens.shellStart),
                                            Color(palette.tokens.shellEnd),
                                            Color(palette.tokens.paneEnd),
                                        ),
                                    ),
                                ),
                            )
                            Text(
                                palette.displayName,
                                modifier = Modifier.weight(1f),
                                fontSize = 12.sp,
                                fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                            )
                            if (active) Text("✓", color = DieterShell, fontWeight = FontWeight.Bold)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SettingsSectionHeader(title: String, subtitle: String) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(title, color = DieterShell, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
        Text(subtitle, color = DieterMuted, fontSize = 14.sp, lineHeight = 20.sp)
    }
}

@Composable
private fun UpdateSettings(manager: AppUpdateManager) {
    val state by manager.state.collectAsStateWithLifecycle()
    val busy = state is AppUpdateState.Checking || state is AppUpdateState.Downloading
    val status = when (val current = state) {
        AppUpdateState.Idle -> if (manager.automaticChecksEnabled) {
            "Checks automatically when Dieter starts."
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
                subtitle = "Checks the official dbpprt/dieter GitHub releases and verifies the APK checksum before install.",
            )
        }
        item {
            Surface(color = DieterSurface, shape = RoundedCornerShape(20.dp), modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Dieter ${manager.currentVersion}", fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
                    Text(
                        status,
                        color = if (state is AppUpdateState.Failed) MaterialTheme.colorScheme.error else DieterMuted,
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
    Surface(color = DieterSurface, shape = RoundedCornerShape(20.dp), modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Glass lens navigation", fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
                    Text(
                        "Floating translucent dock, raised active lens, and balanced navigation slots.",
                        color = DieterMuted,
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
                color = if (enabled) DieterEyes else DieterMuted,
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
            )
        }
    }
}

@Composable
private fun ReasoningTraceSetting(enabled: Boolean, onToggle: (Boolean) -> Unit) {
    Surface(color = DieterSurface, shape = RoundedCornerShape(20.dp), modifier = Modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text("Reasoning traces", fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
                Text(
                    "Hidden by default. Enable this only when you want to inspect model reasoning entries in chats.",
                    color = DieterMuted,
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
            .background(DieterBackground),
        contentAlignment = Alignment.Center,
    ) {
        Surface(
            color = GlassDockFill,
            border = BorderStroke(1.dp, DieterOutline),
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
                                Modifier.size(54.dp).clip(CircleShape).background(DieterShell)
                                    .border(1.dp, Color.White.copy(alpha = 0.35f), CircleShape),
                                contentAlignment = Alignment.Center,
                            ) {
                                Icon(icon, null, tint = DieterAbyss, modifier = Modifier.size(25.dp))
                            }
                        } else {
                            Icon(icon, null, tint = DieterMuted, modifier = Modifier.size(23.dp))
                        }
                    }
                }
            }
        }
    }
}
