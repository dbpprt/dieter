package com.dbpprt.nauclio.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material.icons.outlined.ViewKanban
import androidx.compose.material.icons.outlined.Wifi
import androidx.compose.material3.Icon
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.core.content.ContextCompat
import com.dbpprt.nauclio.NauclioContainer
import com.dbpprt.nauclio.connection.ConnectionPhase
import com.dbpprt.nauclio.connection.EndpointPhase
import com.dbpprt.nauclio.settings.NavigationStyle
import com.dbpprt.nauclio.update.AppUpdateManager
import com.dbpprt.nauclio.ui.theme.NauclioAegean
import com.dbpprt.nauclio.ui.theme.NauclioSeafoam
import com.dbpprt.nauclio.ui.theme.NauclioMuted
import com.dbpprt.nauclio.ui.theme.NauclioSurface
import com.dbpprt.nauclio.ui.theme.NauclioSurfaceHigh
import com.dbpprt.nauclio.ui.theme.NauclioText
import com.dbpprt.nauclio.ui.theme.NauclioOutline
import kotlinx.coroutines.flow.distinctUntilChanged
import com.dbpprt.nauclio.ui.theme.NauclioAbyss
import com.dbpprt.nauclio.ui.theme.NauclioLavenderTint
import com.dbpprt.nauclio.ui.theme.NauclioCoral
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.font.FontFamily

private data class NavItem(
    val destination: Destination,
    val label: String,
    val icon: ImageVector,
)

private val navigationItems = listOf(
    NavItem(Destination.CHATS, "Chats", Icons.Outlined.ChatBubbleOutline),
    NavItem(Destination.BOARD, "Boards", Icons.Outlined.ViewKanban),
    NavItem(Destination.TERMINALS, "Terminal", Icons.Outlined.Terminal),
    NavItem(Destination.FILES, "Files", Icons.Outlined.FolderOpen),
    NavItem(Destination.SCHEDULES, "Schedules", Icons.Outlined.CalendarMonth),
)

internal const val TABLET_LAYOUT_MIN_WIDTH_DP = 600

internal fun usesTabletLayout(availableWidthDp: Float): Boolean =
    availableWidthDp >= TABLET_LAYOUT_MIN_WIDTH_DP

@Composable
fun NauclioApp(container: NauclioContainer) {
    val model: NauclioViewModel = viewModel(
        factory = NauclioViewModel.Factory(container.connectionManager, container.appPreferences),
    )
    val state by model.state.collectAsStateWithLifecycle()
    val openRequest by container.openRequest.collectAsStateWithLifecycle()
    val context = LocalContext.current
    var notificationPermissionRequested by remember { mutableStateOf(false) }
    var fileCreateVisible by remember { mutableStateOf(false) }
    val notificationPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        notificationPermissionRequested = true
    }

    LifecycleEventEffect(Lifecycle.Event.ON_START) { model.start() }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { container.appUpdateManager.refreshInstallerPermission() }
    LifecycleEventEffect(Lifecycle.Event.ON_STOP) { model.stop() }
    LaunchedEffect(container.appUpdateManager) {
        if (container.appUpdateManager.automaticChecksEnabled) {
            container.appUpdateManager.checkForUpdates()
        }
    }
    LaunchedEffect(openRequest) {
        val request = openRequest ?: return@LaunchedEffect
        if (request.showConnection) model.showConnectionDialogIfNeeded()
        if (request.cardId.isNotBlank()) model.openNotificationCard(request.cardId)
        container.consumeOpenRequest(request)
    }
    LaunchedEffect(state.backgroundSyncEnabled, state.desiredConnected) {
        if (
            Build.VERSION.SDK_INT >= 33 &&
            state.backgroundSyncEnabled &&
            state.desiredConnected &&
            !notificationPermissionRequested &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    BackHandler(
        state.appSurface != null || state.terminalCreateVisible || state.selectedCardId != null || state.fileDocument != null ||
            (state.destination == Destination.BOARD && !state.boardOverviewVisible),
    ) {
        when {
            state.appSurface != null -> model.closeSurface()
            state.terminalCreateVisible -> model.dismissTerminalCreate()
            state.fileDocument != null -> model.closeFile()
            state.selectedCardId != null -> model.closeDetail()
            else -> model.showBoardOverview()
        }
    }

    BoxWithConstraints(Modifier.fillMaxSize()) {
        val tabletLayout = usesTabletLayout(maxWidth.value)
        if (state.appSurface != null) {
            Scaffold(containerColor = MaterialTheme.colorScheme.background) { padding ->
                AppSurfaceContent(state, model, container.appUpdateManager, Modifier.fillMaxSize(), padding)
            }
        } else if (tabletLayout) {
            Surface(
                modifier = Modifier.fillMaxSize(),
                color = MaterialTheme.colorScheme.background,
                contentColor = MaterialTheme.colorScheme.onBackground,
            ) {
                Row(Modifier.fillMaxSize()) {
                    NauclioNavigationRail(
                        selected = state.destination,
                        onSelect = model::navigate,
                        onSettings = { model.openSurface(AppSurface.APP_SETTINGS) },
                        onCreate = {
                            when (state.destination) {
                                Destination.CHATS -> model.openSurface(AppSurface.NEW_CHAT)
                                Destination.BOARD -> model.openSurface(
                                    if (state.boardOverviewVisible) AppSurface.NEW_PROJECT else AppSurface.NEW_CARD,
                                )
                                Destination.TERMINALS -> model.showTerminalCreate()
                                Destination.FILES -> fileCreateVisible = true
                                Destination.SCHEDULES -> model.openSurface(AppSurface.SCHEDULE_EDITOR)
                            }
                        },
                    )
                    Box(Modifier.weight(1f).statusBarsPadding()) {
                        DestinationContent(state, model, expanded = true)
                    }
                }
            }
        } else {
            val detailVisible = state.selectedCardId != null || state.fileDocument != null
            val boardLanePagerVisible = state.destination == Destination.BOARD && !state.boardOverviewVisible
            val destination by rememberUpdatedState(state.destination)
            val pagerState = rememberPagerState(
                initialPage = navigationItems.indexOfFirst { it.destination == state.destination }.coerceAtLeast(0),
                pageCount = { navigationItems.size },
            )
            LaunchedEffect(state.destination) {
                val page = navigationItems.indexOfFirst { it.destination == state.destination }.coerceAtLeast(0)
                if (pagerState.currentPage != page) pagerState.animateScrollToPage(page)
            }
            LaunchedEffect(pagerState) {
                snapshotFlow { pagerState.settledPage }
                    .distinctUntilChanged()
                    .collect { page ->
                        val next = navigationItems[page].destination
                        if (next != destination) model.navigate(next)
                    }
            }
            Scaffold(
                containerColor = MaterialTheme.colorScheme.background,
                bottomBar = {
                    if (!detailVisible) {
                        if (state.navigationStyle == NavigationStyle.GLASS) {
                            GlassNavigationDock(
                                state = state,
                                onNavigate = model::navigate,
                                onSettings = { model.openSurface(AppSurface.APP_SETTINGS) },
                            )
                        } else {
                            NauclioBottomBar(
                                selected = state.destination,
                                onSelect = model::navigate,
                                onSettings = { model.openSurface(AppSurface.APP_SETTINGS) },
                            )
                        }
                    }
                },
            ) { padding ->
                HorizontalPager(
                    state = pagerState,
                    modifier = Modifier.fillMaxSize(),
                    userScrollEnabled = !detailVisible && !boardLanePagerVisible,
                    key = { navigationItems[it].destination },
                ) { page ->
                    DestinationContent(
                        destination = navigationItems[page].destination,
                        state = state,
                        model = model,
                        expanded = false,
                        contentPadding = padding,
                    )
                }
            }
        }
        if (state.desiredConnected && state.connectionPhase != ConnectionPhase.CONNECTED) {
            ReconnectingIndicator(
                Modifier.align(Alignment.TopEnd).statusBarsPadding().padding(top = 6.dp, end = 10.dp),
            )
        }
        if (state.connectionDialogVisible) {
            NauclioConnectionDialog(state, model)
        }
        if (fileCreateVisible) {
            FileCreateDialog(
                currentPath = state.filePath,
                onDismiss = { fileCreateVisible = false },
            ) { path, directory ->
                fileCreateVisible = false
                model.createFile(path, directory)
            }
        }
    }
    AppUpdateDialog(container.appUpdateManager)
}

@Composable
private fun ReconnectingIndicator(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .size(32.dp)
            .semantics { contentDescription = "Reconnecting to Nauclio" },
        contentAlignment = Alignment.Center,
    ) {
        CircularProgressIndicator(
            modifier = Modifier.size(17.dp),
            color = NauclioAegean.copy(alpha = 0.82f),
            trackColor = NauclioOutline.copy(alpha = 0.28f),
            strokeWidth = 1.8.dp,
        )
    }
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun NauclioConnectionDialog(state: NauclioUiState, model: NauclioViewModel) {
    val connected = state.connected
    val machines = state.endpointConnections.filter { it.daemonId != null }
    val onlineMachineCount = machines.count { it.online }
    ModalBottomSheet(
        onDismissRequest = { if (connected) model.dismissConnectionDialog() },
        containerColor = NauclioSurface,
    ) {
        Column(
            Modifier.fillMaxWidth().navigationBarsPadding().padding(start = 18.dp, end = 18.dp, bottom = 18.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Surface(
                    shape = RoundedCornerShape(13.dp),
                    color = if (connected) NauclioSeafoam.copy(alpha = 0.13f) else NauclioSurfaceHigh,
                    modifier = Modifier.size(50.dp),
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Icon(
                            Icons.Outlined.Wifi,
                            contentDescription = null,
                            tint = if (connected) NauclioSeafoam else NauclioMuted,
                            modifier = Modifier.size(24.dp),
                        )
                    }
                }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text("Nauclio server", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                    Text(
                        if (machines.isEmpty()) "Discovering enrolled machines"
                        else "$onlineMachineCount of ${machines.size} machines online · automatic routing",
                        color = NauclioAegean,
                        fontSize = 12.sp,
                        modifier = Modifier.clickable(onClick = model::openAppSettingsFromConnection),
                    )
                }
                Surface(
                    shape = RoundedCornerShape(50),
                    color = when (state.connectionPhase) {
                        ConnectionPhase.CONNECTED -> NauclioSeafoam.copy(alpha = 0.14f)
                        ConnectionPhase.UNAVAILABLE, ConnectionPhase.INCOMPATIBLE, ConnectionPhase.AUTH_REQUIRED -> MaterialTheme.colorScheme.error.copy(alpha = 0.12f)
                        else -> NauclioSurfaceHigh
                    },
                ) {
                    Text(
                        when (state.connectionPhase) {
                            ConnectionPhase.CONNECTED -> "● Connected"
                            ConnectionPhase.SYNCING -> "Syncing"
                            ConnectionPhase.RECONNECTING -> "Reconnecting"
                            ConnectionPhase.INCOMPATIBLE -> "Incompatible"
                            ConnectionPhase.UNAVAILABLE -> "Unavailable"
                            ConnectionPhase.AUTH_REQUIRED -> "Sign in required"
                            ConnectionPhase.STOPPED -> "Disconnected"
                            else -> "Connecting"
                        },
                        color = when (state.connectionPhase) {
                            ConnectionPhase.CONNECTED -> NauclioSeafoam
                            ConnectionPhase.UNAVAILABLE, ConnectionPhase.INCOMPATIBLE, ConnectionPhase.AUTH_REQUIRED -> MaterialTheme.colorScheme.error
                            else -> NauclioMuted
                        },
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 7.dp),
                    )
                }
            }
            state.endpointConnections.forEach { endpoint ->
                val endpointConnected = endpoint.phase == EndpointPhase.CONNECTED
                Surface(
                    color = if (endpointConnected) NauclioSeafoam.copy(alpha = 0.08f) else NauclioSurfaceHigh,
                    shape = RoundedCornerShape(16.dp),
                    border = if (endpointConnected) {
                        androidx.compose.foundation.BorderStroke(1.dp, NauclioSeafoam.copy(alpha = 0.45f))
                    } else {
                        null
                    },
                ) {
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        when (endpoint.phase) {
                            EndpointPhase.TRYING -> CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
                            else -> Surface(
                                shape = RoundedCornerShape(50),
                                color = when (endpoint.phase) {
                                    EndpointPhase.CONNECTED -> NauclioSeafoam
                                    EndpointPhase.FAILED -> if (endpoint.online) MaterialTheme.colorScheme.error else NauclioCoral.copy(alpha = 0.7f)
                                    else -> NauclioMuted.copy(alpha = 0.45f)
                                },
                                modifier = Modifier.size(8.dp),
                            ) {}
                        }
                        Spacer(Modifier.width(11.dp))
                        Column(Modifier.weight(1f)) {
                            Text(endpoint.label, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
                            Text(
                                endpoint.address,
                                color = NauclioMuted,
                                fontSize = 11.sp,
                                fontFamily = FontFamily.Monospace,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        Text(
                            endpoint.detail,
                            color = if (endpointConnected) NauclioSeafoam else NauclioMuted,
                            fontSize = 10.sp,
                        )
                    }
                }
            }
            val connectionError = state.connectionError ?: state.error
            if (!connectionError.isNullOrBlank() && !connected) {
                Text(connectionError, color = MaterialTheme.colorScheme.error, fontSize = 11.sp)
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Stay connected in background", fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
                    Text("Persistent notification · polls chats & subagents", color = NauclioMuted, fontSize = 11.sp)
                }
                Switch(checked = state.backgroundSyncEnabled, onCheckedChange = model::setBackgroundSyncEnabled)
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (state.desiredConnected) {
                    OutlinedButton(
                        onClick = model::disconnect,
                        modifier = Modifier.weight(1f),
                        colors = androidx.compose.material3.ButtonDefaults.outlinedButtonColors(contentColor = NauclioCoral),
                        border = androidx.compose.foundation.BorderStroke(1.dp, NauclioCoral.copy(alpha = 0.45f)),
                    ) { Text("Disconnect") }
                    if (state.connectionPhase == ConnectionPhase.AUTH_REQUIRED) {
                        Button(onClick = model::signIn, modifier = Modifier.weight(1f)) { Text("Sign in with GitHub") }
                    } else {
                        Button(onClick = model::dismissConnectionDialog, enabled = connected, modifier = Modifier.weight(1f)) { Text(if (connected) "Done" else "Connecting…") }
                    }
                } else {
                    Button(onClick = model::connect, modifier = Modifier.fillMaxWidth()) { Text("Connect") }
                }
            }
        }
    }
}

@Composable
private fun DestinationContent(
    state: NauclioUiState,
    model: NauclioViewModel,
    expanded: Boolean,
    destination: Destination = state.destination,
    contentPadding: androidx.compose.foundation.layout.PaddingValues = androidx.compose.foundation.layout.PaddingValues(),
) {
    when (destination) {
        Destination.CHATS -> ChatsScreen(state, model, expanded, contentPadding)
        Destination.BOARD -> BoardScreen(state, model, expanded, contentPadding)
        Destination.TERMINALS -> TerminalsScreen(state, model, expanded, contentPadding)
        Destination.FILES -> FilesScreen(state, model, expanded, contentPadding)
        Destination.SCHEDULES -> SchedulesScreen(state, model, contentPadding)
    }
}

@Composable
private fun AppSurfaceContent(
    state: NauclioUiState,
    model: NauclioViewModel,
    updateManager: AppUpdateManager,
    modifier: Modifier,
    contentPadding: androidx.compose.foundation.layout.PaddingValues,
) {
    Box(modifier) {
        when (state.appSurface) {
            AppSurface.NEW_CHAT -> NewConversationScreen(state, model, chat = true, contentPadding = contentPadding)
            AppSurface.NEW_CARD -> NewConversationScreen(state, model, chat = false, contentPadding = contentPadding)
            AppSurface.NEW_BOARD -> NewBoardScreen(state, model, contentPadding = contentPadding)
            AppSurface.SCHEDULE_EDITOR -> ScheduleEditorScreen(
                state = state,
                model = model,
                schedule = state.schedules.firstOrNull { it.id == state.editingScheduleId },
                contentPadding = contentPadding,
            )
            AppSurface.WORKSPACE -> WorkspaceManagementScreen(state, model, contentPadding = contentPadding)
            AppSurface.NEW_PROJECT -> NewProjectScreen(state, model, contentPadding = contentPadding)
            AppSurface.APP_SETTINGS -> AppSettingsScreen(state, model, updateManager, contentPadding = contentPadding)
            null -> Unit
        }
    }
}

@Composable
private fun NauclioBottomBar(
    selected: Destination,
    onSelect: (Destination) -> Unit,
    onSettings: () -> Unit,
) {
    NavigationBar(
        containerColor = NauclioSurface,
        tonalElevation = 0.dp,
        modifier = Modifier.fillMaxWidth(),
    ) {
        navigationItems.forEach { item ->
            NavigationBarItem(
                selected = item.destination == selected,
                onClick = { onSelect(item.destination) },
                icon = { Icon(item.icon, contentDescription = null, modifier = Modifier.size(22.dp)) },
                label = { Text(item.label, fontSize = 11.sp) },
                colors = NavigationBarItemDefaults.colors(
                    selectedIconColor = NauclioText,
                    selectedTextColor = NauclioText,
                    indicatorColor = NauclioLavenderTint,
                    unselectedIconColor = NauclioMuted,
                    unselectedTextColor = NauclioMuted,
                ),
            )
        }
    }
}

@Composable
private fun NauclioNavigationRail(
    selected: Destination,
    onSelect: (Destination) -> Unit,
    onSettings: () -> Unit,
    onCreate: () -> Unit,
) {
    NavigationRail(containerColor = NauclioSurface) {
        Surface(
            onClick = onCreate,
            color = NauclioAegean,
            contentColor = NauclioAbyss,
            shape = RoundedCornerShape(14.dp),
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 14.dp).size(48.dp),
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(Icons.Default.Add, contentDescription = "Create", modifier = Modifier.size(24.dp))
            }
        }
        navigationItems.forEach { item ->
            NavigationRailItem(
                selected = item.destination == selected,
                onClick = { onSelect(item.destination) },
                icon = { Icon(item.icon, contentDescription = null) },
                label = { Text(item.label) },
            )
        }
        NavigationRailItem(
            selected = false,
            onClick = onSettings,
            icon = { Icon(Icons.Outlined.Settings, contentDescription = null) },
            label = { Text("Settings") },
        )
    }
}
