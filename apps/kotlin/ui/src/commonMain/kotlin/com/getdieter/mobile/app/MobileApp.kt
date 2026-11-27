@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.getdieter.mobile.app

import androidx.compose.animation.*
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.SessionSlice
import com.getdieter.mobile.board.*
import com.getdieter.mobile.channels.*
import com.getdieter.mobile.conversation.*
import com.getdieter.mobile.creation.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.mail.*
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.platform.*
import com.getdieter.mobile.screens.*
import com.getdieter.mobile.settings.PairingScreen
import com.getdieter.mobile.share.*
import com.getdieter.mobile.store.*
import com.getdieter.mobile.tools.*
import com.getdieter.mobile.workspace.*
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.TimeSource
import kotlinx.coroutines.delay

/**
 * The touch shell Android hosts on phones, tablets and foldables (see `MobileApp`, which is only
 * compiled for Android and the JVM). iOS hosts each route natively.
 */
@Composable
internal fun MaterialShell(store: MobileStore, openUrl: (String) -> Unit) {
    val session by store.session.slice.collectAsState()
    val workspace by store.workspace.slice.collectAsState()
    val navigation by store.routes.collectAsState()
    val error by store.error.collectAsState()
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(error) {
        if (error.isNotEmpty()) {
            snackbar.showSnackbar(error, withDismissAction = true)
            store.error.value = ""
        }
    }
    val signIn = session.phase == SessionSlice.Phase.PHASE_AUTH_REQUIRED && !workspace.loaded
    SystemBackHandler(
        !signIn &&
            !session.pairing &&
            (navigation.modal != null ||
                navigation.stack.size > 1 ||
                navigation.tab != MobileTab.INBOX)
    ) {
        store.handleBack()
    }
    if (signIn) {
        SignInScreen(store)
        return
    }
    if (session.pairing) {
        PairingScreen(store)
        return
    }
    var moreOpen by remember { mutableStateOf(false) }
    val collapse by store.layout.paneCollapse.collectAsState()
    val style by store.layout.navigationStyle.collectAsState()
    val floating = style != NavigationStyle.CLASSIC
    val backdrop = rememberGlassBackdrop()
    val primarySlot = remember { PrimarySlot() }
    // Lens shrinks to the current tab while a page scrolls down, and returns on the way up or
    // once scrolling has rested for a moment, so the other tabs are never gone for long.
    var minimized by remember { mutableStateOf(false) }
    val scrolled = remember { ScrollRest() }
    // A new page, or the way back to one, always shows every tab.
    LaunchedEffect(navigation.tab, navigation.top, navigation.modal, style) { minimized = false }
    LaunchedEffect(minimized) {
        while (minimized) {
            delay(250)
            if (scrolled.restedFor() >= MinimizedRest) minimized = false
        }
    }
    val minimizer = remember {
        object : NestedScrollConnection {
            override fun onPostScroll(
                consumed: Offset,
                available: Offset,
                source: NestedScrollSource,
            ): Offset {
                if (consumed.y < -8f) {
                    scrolled.mark()
                    minimized = true
                } else if (consumed.y > 8f) minimized = false
                return Offset.Zero
            }
        }
    }
    // The list pane's width in two panes, so the bottom navigation floats beneath the list.
    var listWidth by remember { mutableFloatStateOf(Float.NaN) }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        // Unfolded foldables and tablets show a list beside its detail; landscape phones don't.
        val twoPane = maxWidth >= 600.dp && maxHeight >= 480.dp
        val rail = !floating && maxWidth >= 840.dp
        // With its list sent away, an open conversation fills the screen as on a phone.
        val listHidden = twoPane && collapse.shown(navigation.detailOpen) == PaneCollapse.LIST
        val immersive = (!twoPane || listHidden) && navigation.top.immersive
        // Floating glass stands on the leading edge where height is scarce: landscape two-pane
        // windows and short ones (a phone or a cover screen turned sideways).
        val compact = maxHeight < 480.dp
        val side = floating && !immersive && (compact || (twoPane && maxWidth > maxHeight))
        val bottom = floating && !immersive && !side
        val navBars = WindowInsets.navigationBars
        val base =
            WindowInsets.statusBars.union(
                WindowInsets.displayCutout.only(WindowInsetsSides.Horizontal)
            )
        val classicBottom = if (rail || immersive) navBars else WindowInsets(0, 0, 0, 0)
        // Two panes leave the bar a narrow list pane: it drops its labels there.
        val narrow =
            (if (twoPane && !listHidden && listWidth > 0f && listWidth < maxWidth.value)
                listWidth.dp
            else maxWidth) < DenseNavigation
        // A pane beneath the floating bar runs under it and keeps its last rows clear of it.
        // With the bar at the bottom, pages end above the system navigation bar (see below), so
        // only the floating bar's height is left to keep clear.
        fun paneInsets(beneath: Boolean): WindowInsets {
            val bottomInsets =
                when {
                    !floating -> classicBottom
                    bottom && beneath ->
                        WindowInsets(bottom = style.floatingReserve(false, compact, narrow))
                    bottom -> WindowInsets(0, 0, 0, 0)
                    else -> navBars
                }
            return base.union(bottomInsets)
        }
        val single = paneInsets(beneath = true)
        Row(Modifier.fillMaxSize()) {
            if (rail) NavigationRailBar(store, navigation) { moreOpen = true }
            Column(Modifier.weight(1f)) {
                CompositionLocalProvider(
                    LocalScreenInsets provides single,
                    LocalRailCreates provides rail,
                    LocalPrimarySlot provides if (floating) primarySlot else null,
                ) {
                    Box(
                        Modifier.weight(1f)
                            .glassSource(if (floating) backdrop else null)
                            .nestedScroll(minimizer)
                            // Rows pass under the glass bar but never under the system's
                            // navigation buttons, where a tap would leave the app.
                            .then(
                                if (bottom)
                                    Modifier.windowInsetsPadding(
                                        WindowInsets.navigationBars.only(WindowInsetsSides.Bottom)
                                    )
                                else Modifier
                            )
                            // The side bar keeps a gutter: rows never pass beneath it.
                            .padding(
                                start = if (side) style.floatingReserve(true, compact) else 0.dp
                            )
                    ) {
                        TabStack(
                            store,
                            navigation,
                            twoPane,
                            openUrl,
                            listInsets = single,
                            detailInsets = paneInsets(beneath = listHidden),
                            onListWidth = { listWidth = it },
                        )
                    }
                }
                AnimatedVisibility(
                    !floating && !rail && !immersive,
                    enter = expandVertically(expandFrom = Alignment.Top) + fadeIn(),
                    exit = shrinkVertically(shrinkTowards = Alignment.Top) + fadeOut(),
                ) {
                    BottomBar(store, navigation) { moreOpen = true }
                }
            }
        }
        val onSelect: (MobileTab) -> Unit = { tab ->
            if (tab == MobileTab.MORE) moreOpen = true else store.selectTab(tab)
        }
        // Beneath the list in two panes, else across the window.
        val area =
            if (twoPane && !listHidden && listWidth > 0f && listWidth < maxWidth.value) listWidth.dp
            else maxWidth
        val dense = area < DenseNavigation
        AnimatedVisibility(
            bottom,
            Modifier.align(Alignment.BottomStart).width(area),
            enter = slideInVertically(spring(.8f, 380f)) { it } + fadeIn(),
            exit = slideOutVertically { it } + fadeOut(),
        ) {
            Box(
                Modifier.fillMaxWidth()
                    .windowInsetsPadding(
                        WindowInsets.navigationBars.union(
                            WindowInsets.displayCutout.only(WindowInsetsSides.Horizontal)
                        )
                    )
                    .padding(start = 14.dp, end = 14.dp, bottom = FloatingMargin),
                contentAlignment = Alignment.BottomCenter,
            ) {
                FloatingNavigation(
                    store,
                    navigation,
                    style,
                    vertical = false,
                    compact = compact,
                    dense = dense,
                    backdrop = backdrop,
                    minimized = minimized,
                    moreOpen = false,
                    primary = primarySlot.current,
                    onSelect = onSelect,
                    onExpand = { minimized = false },
                    modifier =
                        if (style == NavigationStyle.ISLAND) Modifier
                        else Modifier.widthIn(max = 560.dp).fillMaxWidth(),
                )
            }
        }
        AnimatedVisibility(
            side,
            Modifier.align(Alignment.CenterStart),
            enter = slideInHorizontally(spring(.8f, 380f)) { -it } + fadeIn(),
            exit = slideOutHorizontally { -it } + fadeOut(),
        ) {
            FloatingNavigation(
                store,
                navigation,
                style,
                vertical = true,
                compact = compact,
                dense = false,
                backdrop = backdrop,
                minimized = false,
                moreOpen = false,
                primary = primarySlot.current,
                onSelect = onSelect,
                onExpand = {},
                modifier =
                    Modifier.windowInsetsPadding(
                            WindowInsets.safeDrawing.only(
                                WindowInsetsSides.Start + WindowInsetsSides.Vertical
                            )
                        )
                        .padding(start = FloatingMargin, top = 8.dp, bottom = 8.dp),
            )
        }
        SnackbarHost(
            snackbar,
            Modifier.align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .padding(
                    bottom =
                        when {
                            bottom -> style.floatingReserve(false, compact, narrow)
                            !floating && !rail && !immersive -> 80.dp
                            else -> 16.dp
                        }
                ),
        )
        if (moreOpen)
            MoreSheet(
                store,
                navigation,
                showBar = !rail && !floating,
                floatingBar =
                    if (!bottom) null
                    else {
                        {
                            FloatingNavigation(
                                store,
                                navigation,
                                style,
                                vertical = false,
                                compact = compact,
                                dense = maxWidth < DenseNavigation,
                                backdrop = null,
                                minimized = false,
                                moreOpen = true,
                                primary = null,
                                onSelect = { tab ->
                                    moreOpen = false
                                    if (tab != MobileTab.MORE) store.selectTab(tab)
                                },
                                onExpand = {},
                                modifier =
                                    if (style == NavigationStyle.ISLAND) Modifier
                                    else Modifier.widthIn(max = 560.dp).fillMaxWidth(),
                            )
                        }
                    },
            ) {
                moreOpen = false
            }
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

/** The bar's items; More opens its sheet instead of switching tabs. */
@Composable
internal fun RowScope.NavigationItems(
    store: MobileStore,
    navigation: MobileNavigation,
    moreOpen: Boolean,
    onSelect: (MobileTab) -> Unit,
) {
    val badge = rememberTabBadges(store)
    MobileTab.entries.forEach { tab ->
        NavigationBarItem(
            selected = if (moreOpen) tab == MobileTab.MORE else navigation.tab == tab,
            onClick = { onSelect(tab) },
            icon = { TabIcon(tab, badge(tab), moreOpen, LocalContentColor.current) },
            label = { Text(tab.title) },
            modifier =
                Modifier.testTag("nav-${tab.name.lowercase()}").semantics {
                    if (tab == MobileTab.MORE)
                        contentDescription = if (moreOpen) "Close More" else "Open More"
                },
        )
    }
}

@Composable
private fun BottomBar(store: MobileStore, navigation: MobileNavigation, onMore: () -> Unit) {
    NavigationBar(containerColor = colors.surfaceContainer) {
        NavigationItems(store, navigation, moreOpen = false) { tab ->
            if (tab == MobileTab.MORE) onMore() else store.selectTab(tab)
        }
    }
}

@Composable
private fun NavigationRailBar(
    store: MobileStore,
    navigation: MobileNavigation,
    onMore: () -> Unit,
) {
    val badge = rememberTabBadges(store)
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
                onClick = { if (tab == MobileTab.MORE) onMore() else store.selectTab(tab) },
                icon = { TabIcon(tab, badge(tab), moreOpen = false, LocalContentColor.current) },
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
    listInsets: WindowInsets,
    detailInsets: WindowInsets,
    onListWidth: (Float) -> Unit,
) {
    val holder = rememberSaveableStateHolder()
    val stack = navigation.stack
    val listIndex = stack.indexOfLast { it.list }
    if (twoPane && listIndex >= 0) {
        val list = stack[listIndex]
        val details = stack.drop(listIndex + 1)
        val detail = details.lastOrNull()
        val collapse by store.layout.paneCollapse.collectAsState()
        // Opening something from a list that fills the window brings the detail back.
        var opened by remember { mutableStateOf(navigation.tab to detail?.key) }
        LaunchedEffect(navigation.tab, detail?.key) {
            val now = navigation.tab to detail?.key
            if (
                now != opened &&
                    now.first == opened.first &&
                    now.second != null &&
                    store.layout.paneCollapse.value == PaneCollapse.DETAIL
            )
                store.layout.setPaneCollapse(PaneCollapse.NONE)
            opened = now
        }
        // Without its list beside it, the open page goes back to the list.
        val listHidden = collapse.shown(detail != null) == PaneCollapse.LIST
        ListDetailSplit(
            store,
            detailOpen = detail != null,
            onListWidth = onListWidth,
            list = {
                CompositionLocalProvider(
                    LocalBackAction provides if (listIndex > 0) store::pop else null,
                    LocalScreenInsets provides listInsets,
                ) {
                    holder.SaveableStateProvider(list.key) { RouteContent(store, list, openUrl) }
                }
            },
        ) {
            Box(Modifier.fillMaxSize()) {
                CompositionLocalProvider(
                    LocalBackAction provides
                        if (details.size > 1 || (listHidden && details.isNotEmpty())) store::pop
                        else null,
                    LocalScreenInsets provides detailInsets,
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
                                val empty = list.emptyDetail(navigation.tab)
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
    SideEffect { onListWidth(Float.NaN) }
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

/** Something is open after the stack's last list, i.e. beside it on wide layouts. */
private val MobileNavigation.detailOpen: Boolean
    get() = stack.indexOfLast { it.list }.let { it >= 0 && it < stack.lastIndex }

private fun depthOf(store: MobileStore, route: MobileRoute): Int =
    store.routes.value.stack.indexOf(route).let { if (it < 0) Int.MAX_VALUE / 2 else it }

/** Shared by the Android host and every native iOS route controller. */
@Composable
internal fun RouteContent(store: MobileStore, route: MobileRoute, openUrl: (String) -> Unit) {
    // A route opened for a new task keeps its local ID; screens follow the server ID once known.
    val outbox by store.workspace.outbox.collectAsState()
    fun card(id: String) = outbox.resolutions[id] ?: id
    when (route) {
        is MobileRoute.Root ->
            when (route.tab) {
                MobileTab.INBOX -> InboxScreen(store)
                MobileTab.PROJECTS -> ProjectsScreen(store)
                MobileTab.MAIL -> MailScreen(store)
                MobileTab.CHATS -> ChatsScreen(store)
                MobileTab.MORE -> MoreScreen(store)
            }
        is MobileRoute.Channels -> ChannelsScreen(store)
        is MobileRoute.Project -> ProjectScreen(store, route.projectId)
        is MobileRoute.Board -> BoardScreen(store, route.boardId)
        is MobileRoute.Conversation -> ConversationScreen(store, card(route.cardId), openUrl)
        is MobileRoute.Channel -> ChannelScreen(store, route.projectId, openUrl)
        is MobileRoute.MailMessage -> MailMessageScreen(store, route, openUrl)
        is MobileRoute.Pane -> CardPaneScreen(store, card(route.cardId), route.pane, openUrl)
        is MobileRoute.Tool -> ToolScreen(store, route, openUrl)
        is MobileRoute.ProviderAccount -> ProviderAccountRoute(store, route, openUrl)
        is MobileRoute.Folder -> com.getdieter.mobile.folders.FolderScreen(store, route.folderId)
        is MobileRoute.FolderFiles ->
            com.getdieter.mobile.folders.FolderFilesScreen(store, route.folderId, route.path)
        is MobileRoute.FolderPage ->
            com.getdieter.mobile.folders.FolderPageScreen(store, route.folderId, route.page)
        is MobileRoute.FolderSync -> com.getdieter.mobile.folders.FolderSyncScreen(store)
        is MobileRoute.CodeReviewer -> com.getdieter.mobile.settings.CodeReviewerScreen(store)
        is MobileRoute.AgentMemory -> com.getdieter.mobile.settings.MemorySettingsScreen(store)
        is MobileRoute.AddFolder ->
            com.getdieter.mobile.folders.AddFolderScreen(store, route.folderId)
        is MobileRoute.SaveToFolder -> com.getdieter.mobile.share.SaveToFolderScreen(store)
        is MobileRoute.NewTask -> CreationScreen(store, route.chat)
        is MobileRoute.ShareTarget -> ShareTargetScreen(store, route.chat)
        is MobileRoute.FilePath ->
            FilesScreen(
                store,
                inConversation = route.cardId.isNotEmpty(),
                route = route,
                openUrl = openUrl,
            )
        is MobileRoute.Machine -> MachineScreen(store, route.machineId)
        is MobileRoute.TerminalSession ->
            TerminalSessionScreen(store, route.terminalId, card(route.cardId))
        is MobileRoute.ScreenSession -> NativeScreen(store, route.machineId)
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
                { store.session.signIn(gateway) },
                Modifier.fillMaxWidth().testTag("sign-in"),
                large = true,
                loading = busy,
                enabled = gateway.length > "https://".length,
            )
        }
    }
}

/**
 * What the iOS app hosts before it shows machine content: sign-in, then pairing until this device
 * is trusted.
 */
@Composable
internal fun SignInContent(store: MobileStore) {
    val session by store.session.slice.collectAsState()
    if (session.pairing) PairingScreen(store) else SignInScreen(store)
}

/** Narrower than this, the bottom navigation shows icons only. */
private val DenseNavigation = 390.dp

/** How long the shrunken Lens bar waits after the last downward scroll before it returns. */
private val MinimizedRest = 1800.milliseconds

/** When a page last scrolled down; read without recomposing the shell on every frame. */
private class ScrollRest {
    private var last = TimeSource.Monotonic.markNow()

    fun mark() {
        last = TimeSource.Monotonic.markNow()
    }

    fun restedFor() = last.elapsedNow()
}
