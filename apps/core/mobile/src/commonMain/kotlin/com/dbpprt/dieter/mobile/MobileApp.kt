@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.mobile

import androidx.compose.animation.*
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.client.v1.SessionSlice

/** Platform hook for system back (Android predictive back). No-op elsewhere. */
@Composable internal expect fun SystemBackHandler(enabled: Boolean, onBack: () -> Unit)

/**
 * The Material host used on Android and in JVM tests. iOS hosts each route natively. [onWindow]
 * receives the theme's darkness and background ARGB so the host can style its window.
 */
@Composable
fun MobileApp(
    store: MobileStore,
    openUrl: (String) -> Unit = {},
    onWindow: (dark: Boolean, background: Int) -> Unit = { _, _ -> },
) {
    val signInUrl by store.signInUrl.collectAsState()
    LaunchedEffect(signInUrl) {
        if (signInUrl.isNotEmpty()) {
            openUrl(signInUrl)
            store.signInUrl.value = ""
        }
    }
    MobileTheme(store, apple = false) {
        val dark = store.isDark()
        val background = palette.background.toArgb()
        SideEffect { onWindow(dark, background) }
        CompositionLocalProvider(LocalMobileStore provides store) {
            Surface(Modifier.fillMaxSize(), color = palette.background) {
                MaterialShell(store, openUrl)
            }
        }
    }
}

@Composable
private fun MaterialShell(store: MobileStore, openUrl: (String) -> Unit) {
    val session by store.session.collectAsState()
    val workspace by store.workspace.collectAsState()
    val navigation by store.routes.collectAsState()
    val error by store.error.collectAsState()
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(error) {
        if (error.isNotEmpty()) {
            snackbar.showSnackbar(error, withDismissAction = true)
            store.error.value = ""
        }
    }
    SystemBackHandler(
        navigation.modal != null || navigation.stack.size > 1 || navigation.tab != MobileTab.INBOX
    ) {
        store.handleBack()
    }
    if (session.phase == SessionSlice.Phase.PHASE_AUTH_REQUIRED && !workspace.loaded) {
        SignInScreen(store)
        return
    }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val rail = maxWidth >= 600.dp
        val twoPane = maxWidth >= 840.dp
        val immersive = !twoPane && navigation.top.immersive
        Row(Modifier.fillMaxSize()) {
            if (rail) NavigationRailBar(store, navigation)
            Column(Modifier.weight(1f)) {
                val bottomInsets =
                    if (rail || immersive) WindowInsets.navigationBars else WindowInsets(0, 0, 0, 0)
                CompositionLocalProvider(
                    LocalScreenInsets provides
                        WindowInsets.statusBars
                            .union(WindowInsets.displayCutout.only(WindowInsetsSides.Horizontal))
                            .union(bottomInsets),
                    LocalRailCreates provides rail,
                ) {
                    Box(Modifier.weight(1f)) { TabStack(store, navigation, twoPane, openUrl) }
                }
                AnimatedVisibility(
                    !rail && !immersive,
                    enter = expandVertically(expandFrom = Alignment.Top) + fadeIn(),
                    exit = shrinkVertically(shrinkTowards = Alignment.Top) + fadeOut(),
                ) {
                    BottomBar(store, navigation)
                }
            }
        }
        SnackbarHost(
            snackbar,
            Modifier.align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .padding(bottom = if (!rail && !immersive) 80.dp else 16.dp),
        )
        val modal = navigation.modal
        AnimatedVisibility(
            modal != null,
            enter = slideInVertically { it / 8 } + fadeIn(tween(220)),
            exit = slideOutVertically { it / 8 } + fadeOut(tween(180)),
        ) {
            val shown = remember(modal) { modal } ?: return@AnimatedVisibility
            CompositionLocalProvider(
                LocalScreenInsets provides WindowInsets.safeDrawing.exclude(WindowInsets.ime)
            ) {
                Surface(Modifier.fillMaxSize(), color = palette.background) {
                    RouteContent(store, shown, openUrl)
                }
            }
        }
    }
}

@Composable
private fun BottomBar(store: MobileStore, navigation: MobileNavigation) {
    val activity by store.activity.collectAsState()
    NavigationBar(containerColor = colors.surfaceContainer) {
        MobileTab.entries.forEach { tab ->
            NavigationBarItem(
                selected = navigation.tab == tab,
                onClick = { store.selectTab(tab) },
                icon = {
                    val attention =
                        if (tab == MobileTab.INBOX) activity.summary?.attention ?: 0 else 0
                    BadgedBox(badge = { if (attention > 0) Badge { Text("$attention") } }) {
                        Icon(tab.glyph, null, size = 24.dp)
                    }
                },
                label = { Text(tab.title) },
                modifier = Modifier.testTag("nav-${tab.name.lowercase()}"),
            )
        }
    }
}

@Composable
private fun NavigationRailBar(store: MobileStore, navigation: MobileNavigation) {
    NavigationRail(
        containerColor = colors.surfaceContainer,
        header = {
            FloatingActionButton(
                onClick = { store.newConversation(navigation.tab == MobileTab.CHATS) },
                modifier = Modifier.padding(top = 8.dp).testTag("rail-new"),
                containerColor = colors.primaryContainer,
            ) {
                Icon(
                    Glyph.COMPOSE,
                    if (navigation.tab == MobileTab.CHATS) "New chat" else "New task",
                    size = 24.dp,
                )
            }
        },
        windowInsets =
            WindowInsets.safeDrawing.only(WindowInsetsSides.Vertical + WindowInsetsSides.Start),
    ) {
        Spacer(Modifier.height(12.dp))
        MobileTab.entries.forEach { tab ->
            NavigationRailItem(
                selected = navigation.tab == tab,
                onClick = { store.selectTab(tab) },
                icon = { Icon(tab.glyph, null, size = 24.dp) },
                label = { Text(tab.title) },
                modifier = Modifier.testTag("nav-${tab.name.lowercase()}"),
            )
        }
    }
}

/** One tab's stack: single pane with shared-axis motion, or list beside detail when wide. */
@Composable
private fun TabStack(
    store: MobileStore,
    navigation: MobileNavigation,
    twoPane: Boolean,
    openUrl: (String) -> Unit,
) {
    val holder = rememberSaveableStateHolder()
    val stack = navigation.stack
    val listIndex = stack.indexOfLast { it.list }
    if (twoPane && listIndex >= 0) {
        val list = stack[listIndex]
        val details = stack.drop(listIndex + 1)
        val detail = details.lastOrNull()
        Row(Modifier.fillMaxSize()) {
            Box(Modifier.width(400.dp).fillMaxHeight()) {
                CompositionLocalProvider(
                    LocalBackAction provides if (listIndex > 0) store::pop else null
                ) {
                    holder.SaveableStateProvider(list.key) { RouteContent(store, list, openUrl) }
                }
            }
            VerticalDivider(color = colors.outlineVariant)
            Box(Modifier.weight(1f).fillMaxHeight()) {
                CompositionLocalProvider(
                    LocalBackAction provides if (details.size > 1) store::pop else null
                ) {
                    AnimatedContent(
                        detail,
                        transitionSpec = { fadeIn(tween(160)) togetherWith fadeOut(tween(120)) },
                    ) { shown ->
                        if (shown == null)
                            Box(
                                Modifier.fillMaxSize().background(palette.background),
                                contentAlignment = Alignment.Center,
                            ) {
                                val empty = navigation.tab.emptyDetail
                                EmptyState(empty.glyph, empty.title, empty.message)
                            }
                        else
                            holder.SaveableStateProvider(shown.key) {
                                RouteContent(store, shown, openUrl)
                            }
                    }
                }
            }
        }
        return
    }
    val depth = stack.size
    AnimatedContent(
        targetState = navigation.tab to stack.last(),
        transitionSpec = {
            val sameTab = initialState.first == targetState.first
            if (!sameTab) fadeIn(tween(160)) togetherWith fadeOut(tween(90))
            else {
                val forward =
                    depthOf(store, targetState.second) >= depthOf(store, initialState.second)
                (slideInHorizontally(tween(300)) { if (forward) it / 6 else -it / 6 } +
                    fadeIn(tween(220))) togetherWith
                    (slideOutHorizontally(tween(300)) { if (forward) -it / 6 else it / 6 } +
                        fadeOut(tween(160)))
            }
        },
        label = "route",
    ) { (_, route) ->
        CompositionLocalProvider(LocalBackAction provides if (depth > 1) store::pop else null) {
            holder.SaveableStateProvider(route.key) { RouteContent(store, route, openUrl) }
        }
    }
}

private fun depthOf(store: MobileStore, route: MobileRoute): Int =
    store.routes.value.stack.indexOf(route).let { if (it < 0) Int.MAX_VALUE / 2 else it }

/** Shared by the Android host and every native iOS route controller. */
@Composable
internal fun RouteContent(store: MobileStore, route: MobileRoute, openUrl: (String) -> Unit) {
    // A route opened for a new task keeps its local ID; screens follow the server ID once known.
    val outbox by store.outbox.collectAsState()
    fun card(id: String) = outbox.resolutions[id] ?: id
    when (route) {
        is MobileRoute.Root ->
            when (route.tab) {
                MobileTab.INBOX -> InboxScreen(store)
                MobileTab.PROJECTS -> ProjectsScreen(store)
                MobileTab.CHATS -> ChatsScreen(store)
                MobileTab.TOOLS -> ToolsScreen(store)
            }
        is MobileRoute.Project -> ProjectScreen(store, route.projectId)
        is MobileRoute.Board -> BoardScreen(store, route.boardId)
        is MobileRoute.Conversation -> ConversationScreen(store, card(route.cardId), openUrl)
        is MobileRoute.Pane -> CardPaneScreen(store, card(route.cardId), route.pane, openUrl)
        is MobileRoute.Tool -> ToolScreen(store, route.page)
        is MobileRoute.NewTask -> CreationScreen(store, route.chat)
        is MobileRoute.FilePath ->
            FilesScreen(store, inConversation = route.cardId.isNotEmpty(), route = route)
        is MobileRoute.Machine -> MachineScreen(store, route.machineId)
        is MobileRoute.TerminalSession ->
            TerminalSessionScreen(store, route.terminalId, card(route.cardId))
        is MobileRoute.ScreenSession -> NativeScreen(store, route.machineId)
    }
}

@Composable
internal fun ToolScreen(store: MobileStore, page: ToolPage) {
    when (page) {
        ToolPage.MACHINES -> MachinesScreen(store)
        ToolPage.TERMINALS -> TerminalsScreen(store)
        ToolPage.SCREENS -> ScreensScreen(store)
        ToolPage.FILES -> FilesScreen(store)
        ToolPage.CHANGES -> ProjectChangesScreen(store)
        ToolPage.SCHEDULES -> SchedulesScreen(store)
        ToolPage.USAGE -> UsageScreen(store)
        ToolPage.SETTINGS -> SettingsScreen(store)
    }
}

@Composable
private fun ToolsScreen(store: MobileStore) {
    val session by store.session.collectAsState()
    val workspace by store.workspace.collectAsState()
    val quotas by store.quotas.collectAsState()
    val selectedProject by store.selectedProject.collectAsState()
    val project = workspace.projects.firstOrNull { it.id == store.currentProjectId() }
    val online = session.machines.count { it.online }
    Screen(ScreenChrome("Tools", large = true)) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("tools-list"),
            state = listState,
            contentPadding = padding,
        ) {
            titleHeader()
            item { ConnectionNotice(store) }
            item { SectionHeader("Machines") }
            item {
                Group(listOf(ToolPage.MACHINES, ToolPage.TERMINALS, ToolPage.SCREENS)) {
                    page,
                    position ->
                    ListRow(
                        page.title,
                        Modifier.testTag("tool-${page.name.lowercase()}"),
                        position = position,
                        glyph = page.glyph,
                        tile = page.color,
                        value =
                            when (page) {
                                ToolPage.MACHINES ->
                                    if (session.machines.isEmpty()) ""
                                    else "$online of ${session.machines.size} online"
                                else -> null
                            },
                        accessory = Accessory.CHEVRON,
                        onClick = {
                            store.showFrom(
                                MobileRoute.Root(MobileTab.TOOLS),
                                MobileRoute.Tool(page),
                            )
                        },
                    )
                }
            }
            item {
                SectionHeader(
                    "Workspace",
                    trailing = {
                        if (project != null)
                            Text(
                                project.name,
                                style = type.footnote,
                                color = palette.secondaryLabel,
                            )
                    },
                )
            }
            item {
                Group(listOf(ToolPage.FILES, ToolPage.CHANGES, ToolPage.SCHEDULES)) { page, position
                    ->
                    ListRow(
                        page.title,
                        Modifier.testTag("tool-${page.name.lowercase()}"),
                        position = position,
                        glyph = page.glyph,
                        tile = page.color,
                        accessory = Accessory.CHEVRON,
                        onClick = {
                            store.showFrom(
                                MobileRoute.Root(MobileTab.TOOLS),
                                MobileRoute.Tool(
                                    page,
                                    selectedProject.ifEmpty { project?.id.orEmpty() },
                                ),
                            )
                        },
                    )
                }
            }
            item { SectionHeader("Account") }
            item {
                Group(listOf(ToolPage.USAGE, ToolPage.SETTINGS)) { page, position ->
                    val lowest =
                        quotas.group_rows
                            .filter { it.lowest_remaining >= 0 }
                            .minOfOrNull { it.lowest_remaining }
                    ListRow(
                        page.title,
                        Modifier.testTag("tool-${page.name.lowercase()}"),
                        position = position,
                        glyph = page.glyph,
                        tile = page.color,
                        value =
                            if (page == ToolPage.USAGE && lowest != null) "$lowest% left" else null,
                        accessory = Accessory.CHEVRON,
                        onClick = {
                            store.showFrom(
                                MobileRoute.Root(MobileTab.TOOLS),
                                MobileRoute.Tool(page),
                            )
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun SignInScreen(store: MobileStore) {
    var gateway by remember { mutableStateOf("https://") }
    val busy by store.busy.collectAsState()
    val error by store.error.collectAsState()
    Box(
        Modifier.fillMaxSize().background(palette.background).safeDrawingPadding().imePadding(),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier.widthIn(max = 440.dp)
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(28.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Box(
                Modifier.size(72.dp)
                    .background(
                        palette.accent,
                        androidx.compose.foundation.shape.RoundedCornerShape(20.dp),
                    ),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Glyph.SPARKLES, null, tint = palette.onAccent, size = 36.dp)
            }
            Spacer(Modifier.height(24.dp))
            Text(
                "Welcome to Dieter",
                style = type.title1,
                color = palette.label,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(8.dp))
            Text(
                "Sign in to your gateway to see your projects, conversations and machines.",
                style = type.body,
                color = palette.secondaryLabel,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(32.dp))
            MobileTextField(
                gateway,
                { gateway = it },
                Modifier.fillMaxWidth().testTag("gateway-address"),
                label = { Text("Gateway address") },
                singleLine = true,
            )
            if (error.isNotEmpty()) {
                Spacer(Modifier.height(12.dp))
                Text(error, style = type.footnote, color = palette.destructive)
            }
            Spacer(Modifier.height(20.dp))
            DButton(
                "Sign in",
                { store.signIn(gateway) },
                Modifier.fillMaxWidth().testTag("sign-in"),
                large = true,
                loading = busy,
                enabled = gateway.length > "https://".length,
            )
        }
    }
}

/** Sign-in screen hosted directly by the iOS app before a session exists. */
@Composable internal fun SignInContent(store: MobileStore) = SignInScreen(store)

@Composable
internal fun Placeholder(text: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(
            text,
            style = type.body.copy(fontWeight = FontWeight.Medium),
            color = palette.secondaryLabel,
        )
    }
}
