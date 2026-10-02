package com.dbpprt.dieter.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.interaction.collectIsDraggedAsState
import androidx.compose.foundation.clickable
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
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
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material.icons.outlined.Wifi
import androidx.compose.material.icons.outlined.WifiOff
import androidx.compose.material3.Icon
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.pageLeft
import androidx.compose.ui.semantics.pageRight
import androidx.compose.ui.semantics.scrollBy
import androidx.compose.ui.semantics.scrollToIndex
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.core.content.ContextCompat
import com.dbpprt.dieter.DieterContainer
import com.dbpprt.dieter.core.connection.Availability
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.core.machines.MachineLink
import com.dbpprt.dieter.core.machines.MachineRows
import com.dbpprt.dieter.core.navigation.Destination
import com.dbpprt.dieter.update.AppUpdateManager
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterEyes
import com.dbpprt.dieter.ui.theme.DieterAmber
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterSurface
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh
import com.dbpprt.dieter.ui.theme.DieterText
import kotlin.time.Clock
import kotlin.time.Instant
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.delay
import com.dbpprt.dieter.ui.theme.DieterCoral
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.font.FontFamily

internal const val TABLET_LAYOUT_MIN_WIDTH_DP = 600

internal fun usesTabletLayout(availableWidthDp: Float): Boolean =
    availableWidthDp >= TABLET_LAYOUT_MIN_WIDTH_DP

@Composable
fun DieterApp(container: DieterContainer) {
    val model: DieterViewModel = viewModel(
        factory = DieterViewModel.Factory(
            container.core,
            container.appPreferences,
            container.policy,
            container,
            container.taskCaptures,
        ),
    )
    val state by model.state.collectAsStateWithLifecycle()
    val captures by container.taskCaptures.view.collectAsStateWithLifecycle()
    if (!captures.bound) {
        androidx.compose.material3.CircularProgressIndicator()
        return
    }
    TaskCaptureHost(state, model, container.taskCaptures)
    val openRequest by container.openRequest.collectAsStateWithLifecycle()
    val context = LocalContext.current
    var notificationPermissionRequested by remember { mutableStateOf(false) }
    var fileCreateVisible by remember { mutableStateOf(false) }
    var toolsOpen by rememberSaveable { mutableStateOf(false) }
    var projectPickerTarget by remember { mutableStateOf<Destination?>(null) }
    val notificationPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        notificationPermissionRequested = true
    }

    LifecycleEventEffect(Lifecycle.Event.ON_START) { model.start() }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { container.appUpdateManager.refreshInstallerPermission() }
    LifecycleEventEffect(Lifecycle.Event.ON_STOP) { container.taskCaptures.flushAll(); model.stop() }
    LaunchedEffect(container.appUpdateManager) {
        if (container.appUpdateManager.automaticChecksEnabled) {
            container.appUpdateManager.checkForUpdates()
        }
    }
    LaunchedEffect(openRequest, state.loading, state.spaceCards, state.chats, state.connectionPhase) {
        val request = openRequest ?: return@LaunchedEffect
        if (request.showConnection) model.showConnectionDialogIfNeeded()
        // A cold launch keeps the request until cached state or the first live projection arrives.
        if ((request.showInbox || request.cardId.isNotBlank()) && !model.openRequested(request.cardId, inInbox = request.showInbox)) return@LaunchedEffect
        container.consumeOpenRequest(request)
    }
    LaunchedEffect(state.backgroundSyncMode, state.desiredConnected) {
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

    // Files and Schedules are project-scoped tools.
    // Tapping either offers a project picker so the surface never falls back to a stale project.
    val handleNavigate: (Destination) -> Unit = { destination ->
        toolsOpen = false
        if (!destination.projectScoped || state.projectSurfacesEnabled) {
            if (destination.projectScoped && state.projects.size > 1) {
                projectPickerTarget = destination
            } else {
                model.navigate(destination)
            }
        }
    }

    BoxWithConstraints(Modifier.fillMaxSize()) {
        val tabletLayout = usesTabletLayout(maxWidth.value)
        val tabletWorkspace = usesTabletWorkspace(maxWidth.value)
        val synchronizedWorkspaceVisible = state.appSurface == null && state.destination.synchronized
        val workspaceStatusIsInline = synchronizedWorkspaceVisible && (state.hasCachedWorkspace ||
            Availability.initialSync(state.destination, state.hasCachedWorkspace, state.loading, state.desiredConnected, state.connectionPhase))
        val globalConnectionStatusVisible =
            state.connectionPhase != ConnectionPhase.CONNECTED && !workspaceStatusIsInline
        // Tools is modal inside this window: its scrim handles pointer input,
        // and underlying destinations leave the accessibility/focus traversal.
        Box(Modifier.fillMaxSize().then(if (toolsOpen) Modifier
            .clearAndSetSemantics { }.focusProperties { canFocus = false } else Modifier)) {
            if (tabletWorkspace) {
                TabletWorkspace(
                    state = state,
                    model = model,
                    destinationContent = { tabletState ->
                        BoxWithConstraints(Modifier.fillMaxSize()) {
                            DestinationContent(tabletState, model, expanded = usesTabletLayout(maxWidth.value))
                        }
                    },
                    surfaceContent = { AppSurfaceContent(state, model, container.appUpdateManager, Modifier.fillMaxSize(), PaddingValues()) },
                    statusContent = {
                        if (globalConnectionStatusVisible) ConnectionStatusIndicator(
                            phase = state.connectionPhase,
                            lastConnectedAtMillis = state.lastConnectedAtMillis,
                            showingCachedData = state.hasCachedWorkspace,
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 6.dp),
                        )
                    },
                )
            } else if (state.appSurface != null) {
                Scaffold(
                    containerColor = MaterialTheme.colorScheme.background,
                    topBar = {
                        if (globalConnectionStatusVisible) {
                            ConnectionStatusTopBar(
                                phase = state.connectionPhase,
                                lastConnectedAtMillis = state.lastConnectedAtMillis,
                                showingCachedData = state.hasCachedWorkspace,
                            )
                        }
                    },
                ) { padding ->
                    AppSurfaceContent(state, model, container.appUpdateManager, Modifier.fillMaxSize(), padding)
                }
            } else if (tabletLayout) {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background,
                    contentColor = MaterialTheme.colorScheme.onBackground,
                ) {
                    Row(Modifier.fillMaxSize()) {
                        DieterNavigationRail(
                            selected = state.destination,
                            onSelect = handleNavigate,
                            projectSurfacesEnabled = state.projectSurfacesEnabled,
                            onSettings = { model.openSurface(AppSurface.APP_SETTINGS) },
                            onCreate = {
                                when (state.destination) {
                                    Destination.ACTIVITY, Destination.CHATS -> model.openSurface(AppSurface.NEW_CHAT)
                                    Destination.BOARD -> model.openSurface(
                                        if (state.boardOverviewVisible) AppSurface.NEW_PROJECT else AppSurface.NEW_CARD,
                                    )
                                    Destination.MACHINES, Destination.SCREENS -> Unit
                                    Destination.TERMINALS -> model.showTerminalCreate()
                                    Destination.FILES -> fileCreateVisible = true
                                    Destination.SCHEDULES -> model.openSurface(AppSurface.SCHEDULE_EDITOR)
                                }
                            },
                        )
                        Column(Modifier.weight(1f).fillMaxHeight()) {
                            if (globalConnectionStatusVisible) {
                                ConnectionStatusTopBar(
                                    phase = state.connectionPhase,
                                    lastConnectedAtMillis = state.lastConnectedAtMillis,
                                    showingCachedData = state.hasCachedWorkspace,
                                )
                            }
                            Box(
                                Modifier.weight(1f).fillMaxWidth().then(
                                    if (globalConnectionStatusVisible) Modifier else Modifier.statusBarsPadding(),
                                ),
                            ) {
                                DestinationContent(state, model, expanded = true)
                            }
                        }
                    }
                }
            } else {
                val detailVisible = state.selectedCardId != null || state.fileDocument != null
                val boardLanePagerVisible = state.destination == Destination.BOARD && !state.boardOverviewVisible
                Scaffold(
                    containerColor = MaterialTheme.colorScheme.background,
                    topBar = {
                        if (globalConnectionStatusVisible) {
                            ConnectionStatusTopBar(
                                phase = state.connectionPhase,
                                lastConnectedAtMillis = state.lastConnectedAtMillis,
                                showingCachedData = state.hasCachedWorkspace,
                            )
                        }
                    },
                    bottomBar = {
                        if (!detailVisible) {
                            val toolsFocus = remember { FocusRequester() }
                            var toolsWereOpen by remember { mutableStateOf(false) }
                            LaunchedEffect(toolsOpen) {
                                if (toolsOpen) toolsWereOpen = true
                                else if (toolsWereOpen) {
                                    toolsWereOpen = false
                                    toolsFocus.requestFocus()
                                }
                            }
                            DieterBottomBar(
                                selected = state.destination,
                                onSelect = handleNavigate,
                                onTools = { toolsOpen = true },
                                toolsFocusRequester = toolsFocus,
                            )
                        }
                    },
                ) { padding ->
                    if (state.destination.isPrimaryDestination()) {
                        PrimaryDestinationPager(
                            state = state,
                            model = model,
                            contentPadding = padding,
                            userScrollEnabled = !detailVisible && !boardLanePagerVisible,
                        )
                    } else {
                        DestinationContent(state, model, expanded = false, contentPadding = padding)
                    }
                }
            }
        }
        if (toolsOpen && state.appSurface == null) {
            DieterToolsSheet(
                selected = state.destination,
                projectSurfacesEnabled = state.projectSurfacesEnabled,
                onSelect = handleNavigate,
                onSettings = {
                    toolsOpen = false
                    model.openSurface(AppSurface.APP_SETTINGS)
                },
                onDismiss = { toolsOpen = false },
            )
        }
        if (state.connectionDialogVisible) {
            DieterConnectionDialog(state, model)
        }
        if (fileCreateVisible) {
            FileCreateDialog(
                currentPath = state.filePath,
                onDismiss = { fileCreateVisible = false },
            ) { name, directory ->
                fileCreateVisible = false
                model.createFile(name, directory)
            }
        }
        projectPickerTarget?.let { target ->
            ProjectPickerSheet(
                state = state,
                target = target,
                onDismiss = { projectPickerTarget = null },
                onSelect = { projectId ->
                    projectPickerTarget = null
                    if (projectId != state.selectedProjectId) model.selectProject(projectId)
                    model.navigate(target)
                },
            )
        }
    }
    AppUpdateDialog(container.appUpdateManager)
}

@Composable
private fun PrimaryDestinationPager(
    state: DieterUiState,
    model: DieterViewModel,
    contentPadding: PaddingValues,
    userScrollEnabled: Boolean,
) {
    val selectedPage = primaryNavigationItems.indexOfFirst { it.destination == state.destination }.coerceAtLeast(0)
    val pagerState = rememberPagerState(
        initialPage = selectedPage,
        pageCount = { primaryNavigationItems.size },
    )
    val isDragged by pagerState.interactionSource.collectIsDraggedAsState()
    val rightStep = if (LocalLayoutDirection.current == LayoutDirection.Rtl) -1 else 1
    fun selectPage(page: Int): Boolean {
        if (!userScrollEnabled || page !in primaryNavigationItems.indices || page == selectedPage) return false
        model.navigate(primaryNavigationItems[page].destination)
        return true
    }
    LaunchedEffect(selectedPage, userScrollEnabled, pagerState) {
        // A tab tap selects its destination immediately. Animating a full
        // pager here repeatedly lays out every intervening page and delays
        // input readiness; gesture-driven swipes retain the pager animation.
        // Synchronize before observing, so programmatic route changes cannot
        // race the observer and be mistaken for a completed user scroll.
        if (pagerState.currentPage != selectedPage) pagerState.scrollToPage(selectedPage)
        var observedDrag = false
        snapshotFlow { Triple(pagerState.settledPage, pagerState.isScrollInProgress, isDragged) }
            .distinctUntilChanged()
            .collect { (page, scrolling, dragging) ->
                if (dragging) observedDrag = true
                if (!scrolling && !dragging) {
                    val completedDrag = observedDrag
                    observedDrag = false
                    // Detail/IME layout and focus requests can scroll the
                    // pager too. Only a completed drag selects another route;
                    // programmatic movement follows the selected destination.
                    if (page != selectedPage) {
                        if (completedDrag && userScrollEnabled) model.navigate(primaryNavigationItems[page].destination)
                        else pagerState.scrollToPage(selectedPage)
                    }
                }
            }
    }
    HorizontalPager(
        state = pagerState,
        modifier = Modifier.fillMaxSize().testTag("primary-navigation-pager").semantics {
            // Accessibility scroll actions also express navigation intent;
            // focus/bring-into-view scrolling does not.
            if (userScrollEnabled) {
                pageLeft { selectPage(selectedPage - rightStep) }
                pageRight { selectPage(selectedPage + rightStep) }
                scrollToIndex { selectPage(it) }
                scrollBy { x, _ ->
                    when {
                        x > 0 -> selectPage(selectedPage + rightStep)
                        x < 0 -> selectPage(selectedPage - rightStep)
                        else -> false
                    }
                }
            }
        },
        userScrollEnabled = userScrollEnabled,
        beyondViewportPageCount = 1,
        key = { primaryNavigationItems[it].destination },
    ) { page ->
        val pageDestination = primaryNavigationItems[page].destination
        val pageState = remember(pageDestination) { PrimaryPageState(pageDestination) }.project(state)
        DestinationContent(
            destination = pageDestination,
            state = pageState,
            model = model,
            expanded = false,
            contentPadding = contentPadding,
        )
    }
}

@Composable
internal fun ConnectionStatusTopBar(
    phase: ConnectionPhase,
    lastConnectedAtMillis: Long?,
    showingCachedData: Boolean,
) {
    ConnectionStatusIndicator(
        phase = phase,
        lastConnectedAtMillis = lastConnectedAtMillis,
        showingCachedData = showingCachedData,
        modifier = Modifier.fillMaxWidth().statusBarsPadding()
            .padding(start = 10.dp, top = 6.dp, end = 10.dp, bottom = 4.dp),
    )
}

@Composable
internal fun ConnectionStatusIndicator(
    phase: ConnectionPhase,
    lastConnectedAtMillis: Long?,
    showingCachedData: Boolean,
    supportsOfflineOutbox: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val presentation = Availability.notice(phase, showingCachedData, supportsOfflineOutbox)
    val accent = if (presentation.offline) DieterCoral else DieterAmber
    var nowMillis by remember(lastConnectedAtMillis) { mutableStateOf(System.currentTimeMillis()) }
    LaunchedEffect(lastConnectedAtMillis) {
        while (true) {
            delay(30_000L)
            nowMillis = System.currentTimeMillis()
        }
    }
    val freshness = Availability.updated(lastConnectedAtMillis?.let(Instant::fromEpochMilliseconds), Instant.fromEpochMilliseconds(nowMillis))
    val content = "${presentation.title}. ${presentation.detail} $freshness."
    Surface(
        modifier = modifier.testTag("workspace-connection-status"),
        shape = RoundedCornerShape(16.dp),
        color = accent.copy(alpha = 0.055f),
        border = BorderStroke(1.dp, accent.copy(alpha = 0.16f)),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 54.dp)
                .padding(horizontal = 11.dp, vertical = 8.dp)
                .semantics { contentDescription = content },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            Surface(shape = RoundedCornerShape(50), color = accent.copy(alpha = 0.12f), modifier = Modifier.size(28.dp)) {
                Box(contentAlignment = Alignment.Center) {
                    if (presentation.working) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(14.dp),
                            color = accent,
                            trackColor = accent.copy(alpha = 0.18f),
                            strokeWidth = 1.8.dp,
                        )
                    } else {
                        Icon(
                            Icons.Outlined.WifiOff,
                            contentDescription = null,
                            tint = accent,
                            modifier = Modifier.size(13.dp),
                        )
                    }
                }
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Text(
                    presentation.title,
                    color = DieterText,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    presentation.detail,
                    color = DieterMuted,
                    fontSize = 10.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Surface(shape = RoundedCornerShape(50), color = DieterSurfaceHigh.copy(alpha = 0.72f)) {
                Text(
                    freshness,
                    color = DieterMuted,
                    fontSize = 9.sp,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 5.dp),
                )
            }
        }
    }
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun DieterConnectionDialog(state: DieterUiState, model: DieterViewModel) {
    val connected = state.connected
    val machines = MachineRows.listed(state.presentedEndpointConnections)
    val now = Clock.System.now()
    ModalBottomSheet(
        onDismissRequest = model::dismissConnectionDialog,
        containerColor = DieterSurface,
    ) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding()
                .padding(start = 18.dp, end = 18.dp, bottom = 18.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Surface(
                    shape = RoundedCornerShape(13.dp),
                    color = if (connected) DieterEyes.copy(alpha = 0.13f) else DieterSurfaceHigh,
                    modifier = Modifier.size(50.dp),
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Icon(
                            Icons.Outlined.Wifi,
                            contentDescription = null,
                            tint = if (connected) DieterEyes else DieterMuted,
                            modifier = Modifier.size(24.dp),
                        )
                    }
                }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text("Dieter server", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                    Text(
                        MachineRows.onlineSummary(machines) + if (machines.isEmpty()) "" else " · automatic routing",
                        color = DieterShell,
                        fontSize = 12.sp,
                        modifier = Modifier.clickable(onClick = model::openAppSettingsFromConnection),
                    )
                }
                Surface(
                    shape = RoundedCornerShape(50),
                    color = when {
                        connected -> DieterEyes.copy(alpha = 0.14f)
                        Availability.blocked(state.connectionPhase) -> MaterialTheme.colorScheme.error.copy(alpha = 0.12f)
                        else -> DieterSurfaceHigh
                    },
                ) {
                    Text(
                        if (connected) "● ${Availability.label(state.connectionPhase)}" else Availability.label(state.connectionPhase),
                        color = when {
                            connected -> DieterEyes
                            Availability.blocked(state.connectionPhase) -> MaterialTheme.colorScheme.error
                            else -> DieterMuted
                        },
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 7.dp),
                    )
                }
            }
            machines.forEach { endpoint ->
                val endpointConnected = endpoint.phase == MachineLink.CONNECTED
                val outboxSummary = state.machineOutboxSummaries[endpoint.id]
                Surface(
                    color = if (endpointConnected) DieterEyes.copy(alpha = 0.08f) else DieterSurfaceHigh,
                    shape = RoundedCornerShape(16.dp),
                    border = if (endpointConnected) {
                        androidx.compose.foundation.BorderStroke(1.dp, DieterEyes.copy(alpha = 0.45f))
                    } else {
                        null
                    },
                ) {
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        when (endpoint.phase) {
                            MachineLink.TRYING -> CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
                            else -> Surface(
                                shape = RoundedCornerShape(50),
                                color = when (endpoint.phase) {
                                    MachineLink.CONNECTED -> DieterEyes
                                    MachineLink.FAILED -> if (endpoint.online) MaterialTheme.colorScheme.error else DieterCoral.copy(alpha = 0.7f)
                                    else -> DieterMuted.copy(alpha = 0.45f)
                                },
                                modifier = Modifier.size(8.dp),
                            ) {}
                        }
                        Spacer(Modifier.width(11.dp))
                        Column(Modifier.weight(1f)) {
                            Text(endpoint.label, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
                            Text(
                                endpoint.address,
                                color = DieterMuted,
                                fontSize = 11.sp,
                                fontFamily = FontFamily.Monospace,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        Text(
                            state.machineStatusLine(endpoint, now) + outboxSummary?.statusSuffix.orEmpty(),
                            color = if (endpointConnected) DieterEyes else DieterMuted,
                            fontSize = 10.sp,
                        )
                    }
                }
                if (outboxSummary?.storageBanner == true) {
                    StorageDeliveryBanner(
                        machineName = endpoint.label,
                        detail = outboxSummary.detail(endpoint.label, endpoint.online),
                        onRetry = { model.retryOutboxForEndpoint(endpoint.id) },
                    )
                } else if (outboxSummary != null) {
                    val retryTitle = outboxSummary.retryTitle(endpoint.online)
                    Surface(
                        color = DieterAmber.copy(alpha = 0.08f),
                        shape = RoundedCornerShape(16.dp),
                        border = BorderStroke(1.dp, DieterAmber.copy(alpha = 0.42f)),
                        modifier = Modifier.fillMaxWidth().testTag("machine-queue-${endpoint.id}"),
                    ) {
                        Row(
                            Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(Icons.Outlined.WifiOff, null, tint = DieterAmber, modifier = Modifier.size(20.dp))
                            Spacer(Modifier.width(10.dp))
                            Column(Modifier.weight(1f)) {
                                Text(
                                    outboxSummary.title(endpoint.label, endpoint.online),
                                    color = DieterAmber,
                                    fontWeight = FontWeight.SemiBold,
                                    fontSize = 13.sp,
                                )
                                Text(outboxSummary.detail(endpoint.label, endpoint.online), color = DieterMuted, fontSize = 11.sp)
                            }
                            if (retryTitle.isNotEmpty()) {
                                Spacer(Modifier.width(8.dp))
                                OutlinedButton(
                                    onClick = { model.retryOutboxForEndpoint(endpoint.id) },
                                    border = BorderStroke(1.dp, DieterAmber.copy(alpha = 0.5f)),
                                    modifier = Modifier.testTag("machine-retry-${endpoint.id}"),
                                ) { Text(retryTitle, color = DieterAmber, fontSize = 11.sp) }
                            }
                        }
                    }
                }
            }
            val connectionError = state.connectionError ?: state.error
            if (!connectionError.isNullOrBlank() && !connected) {
                Text(connectionError, color = MaterialTheme.colorScheme.error, fontSize = 11.sp)
            }
            BackgroundSyncModeSelector(state.backgroundSyncMode, model::setBackgroundSyncMode)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (state.desiredConnected) {
                    OutlinedButton(
                        onClick = model::disconnect,
                        modifier = Modifier.weight(1f),
                        colors = androidx.compose.material3.ButtonDefaults.outlinedButtonColors(contentColor = DieterCoral),
                        border = androidx.compose.foundation.BorderStroke(1.dp, DieterCoral.copy(alpha = 0.45f)),
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
    state: DieterUiState,
    model: DieterViewModel,
    expanded: Boolean,
    destination: Destination = state.destination,
    contentPadding: PaddingValues = PaddingValues(),
) {
    if (Availability.initialSync(destination, state.hasCachedWorkspace, state.loading, state.desiredConnected, state.connectionPhase)) {
        InitialWorkspaceSyncState(
            phase = state.connectionPhase,
            modifier = Modifier.fillMaxSize().padding(contentPadding),
        )
        return
    }
    val treatment = Availability.treatment(destination, state.hasCachedWorkspace, state.connectionPhase)
    val blocksInteraction = Availability.blocksInteraction(destination, state.hasCachedWorkspace, state.connectionPhase)
    val layoutDirection = LocalLayoutDirection.current
    val destinationPadding = if (treatment.showsNotice) {
        PaddingValues(
            start = if (layoutDirection == LayoutDirection.Ltr) {
                contentPadding.calculateLeftPadding(layoutDirection)
            } else {
                contentPadding.calculateRightPadding(layoutDirection)
            },
            top = 0.dp,
            end = if (layoutDirection == LayoutDirection.Ltr) {
                contentPadding.calculateRightPadding(layoutDirection)
            } else {
                contentPadding.calculateLeftPadding(layoutDirection)
            },
            bottom = contentPadding.calculateBottomPadding(),
        )
    } else {
        contentPadding
    }
    Column(Modifier.fillMaxSize()) {
        if (treatment.showsNotice) {
            ConnectionStatusIndicator(
                phase = state.connectionPhase,
                lastConnectedAtMillis = state.lastConnectedAtMillis,
                showingCachedData = true,
                supportsOfflineOutbox = destination.offlineOutbox,
                modifier = Modifier.fillMaxWidth().padding(
                    start = 10.dp,
                    top = contentPadding.calculateTopPadding() + 6.dp,
                    end = 10.dp,
                    bottom = 4.dp,
                ),
            )
        }
        Box(Modifier.fillMaxSize().weight(1f)) {
            Box(Modifier.fillMaxSize().alpha(if (blocksInteraction) 0.82f else 1f)) {
                when (destination) {
                    Destination.ACTIVITY -> ActivityScreen(state, model, expanded, destinationPadding)
                    Destination.CHATS -> ChatsScreen(state, model, expanded, destinationPadding)
                    Destination.BOARD -> BoardScreen(state, model, expanded, destinationPadding)
                    Destination.MACHINES -> MachinesScreen(state, model, expanded, destinationPadding)
                    Destination.SCREENS -> ScreensScreen(state, destinationPadding)
                    Destination.TERMINALS -> TerminalsScreen(state, model, expanded, destinationPadding)
                    Destination.FILES -> FilesScreen(state, model, expanded, destinationPadding)
                    Destination.SCHEDULES -> SchedulesScreen(state, model, destinationPadding)
                }
            }
            if (blocksInteraction) {
                Spacer(
                    Modifier
                        .matchParentSize()
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                            onClick = {},
                        )
                        .semantics { contentDescription = "Cached workspace is read-only until Dieter reconnects" },
                )
            }
        }
    }
}

@Composable
internal fun InitialWorkspaceSyncState(
    phase: ConnectionPhase,
    modifier: Modifier = Modifier,
) {
    val presentation = Availability.firstSync(phase)
    val accent = if (presentation.working) DieterAmber else DieterCoral
    Box(
        modifier = modifier
            .testTag("workspace-initial-sync")
            .semantics { contentDescription = "${presentation.title}. ${presentation.detail}" },
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 36.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Surface(
                shape = RoundedCornerShape(24.dp),
                color = accent.copy(alpha = 0.08f),
                border = BorderStroke(1.dp, accent.copy(alpha = 0.14f)),
                modifier = Modifier.size(72.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    if (presentation.working) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(42.dp),
                            color = accent,
                            trackColor = accent.copy(alpha = 0.16f),
                            strokeWidth = 2.dp,
                        )
                        Icon(Icons.Outlined.Sync, contentDescription = null, tint = accent, modifier = Modifier.size(17.dp))
                    } else {
                        Icon(Icons.Outlined.WifiOff, contentDescription = null, tint = accent, modifier = Modifier.size(24.dp))
                    }
                }
            }
            Spacer(Modifier.height(2.dp))
            Text(
                presentation.title,
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
            )
            Text(
                presentation.detail,
                color = DieterMuted,
                fontSize = 13.sp,
                lineHeight = 19.sp,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun AppSurfaceContent(
    state: DieterUiState,
    model: DieterViewModel,
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
