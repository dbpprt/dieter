@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.getdieter.mobile.app

import androidx.compose.animation.*
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
import androidx.compose.ui.graphics.toArgb
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
    val signInUrl by store.session.signInUrl.collectAsState()
    LaunchedEffect(signInUrl) {
        if (signInUrl.isNotEmpty()) {
            openUrl(signInUrl)
            store.session.signInUrl.value = ""
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
    BoxWithConstraints(Modifier.fillMaxSize()) {
        // Unfolded foldables and tablets show a list beside its detail; landscape phones don't.
        val twoPane = maxWidth >= 600.dp && maxHeight >= 480.dp
        val rail = maxWidth >= 840.dp
        val immersive = !twoPane && navigation.top.immersive
        Row(Modifier.fillMaxSize()) {
            if (rail) NavigationRailBar(store, navigation) { moreOpen = true }
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
                    BottomBar(store, navigation) { moreOpen = true }
                }
            }
        }
        SnackbarHost(
            snackbar,
            Modifier.align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .padding(bottom = if (!rail && !immersive) 80.dp else 16.dp),
        )
        if (moreOpen) MoreSheet(store, navigation, showBar = !rail) { moreOpen = false }
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

/** Each tab's badge: Inbox attention; More counts unread mail and channel messages. */
@Composable
private fun rememberTabBadges(store: MobileStore): (MobileTab) -> String {
    val activity by store.workspace.activity.collectAsState()
    val channels by store.channels.slice.collectAsState()
    val mail by store.mail.slice.collectAsState()
    val attention = activity.summary?.attention ?: 0
    return { tab ->
        when (tab) {
            MobileTab.INBOX -> if (attention > 0) attention.toString() else ""
            MobileTab.MORE -> moreBadge(mail.unread, channels.unread)
            else -> ""
        }
    }
}

/** More shows a grid until its sheet is open, then the chevron that closes it. */
@Composable
private fun TabIcon(tab: MobileTab, badge: String, moreOpen: Boolean) {
    BadgedBox(badge = { if (badge.isNotEmpty() && !moreOpen) Badge { Text(badge) } }) {
        Crossfade(tab == MobileTab.MORE && moreOpen, label = "more") { open ->
            Icon(if (open) Glyph.CHEVRON_DOWN else tab.glyph, null, size = 24.dp)
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
            icon = { TabIcon(tab, badge(tab), moreOpen) },
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
                icon = { TabIcon(tab, badge(tab), moreOpen = false) },
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
        ListDetailSplit(
            store,
            list = {
                CompositionLocalProvider(
                    LocalBackAction provides if (listIndex > 0) store::pop else null
                ) {
                    holder.SaveableStateProvider(list.key) { RouteContent(store, list, openUrl) }
                }
            },
        ) {
            Box(Modifier.fillMaxSize()) {
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
    val outbox by store.workspace.outbox.collectAsState()
    fun card(id: String) = outbox.resolutions[id] ?: id
    when (route) {
        is MobileRoute.Root ->
            when (route.tab) {
                MobileTab.INBOX -> InboxScreen(store)
                MobileTab.PROJECTS -> ProjectsScreen(store)
                MobileTab.CHATS -> ChatsScreen(store)
                MobileTab.MORE -> MoreScreen(store)
            }
        is MobileRoute.Mailbox -> MailScreen(store)
        is MobileRoute.Channels -> ChannelsScreen(store)
        is MobileRoute.Project -> ProjectScreen(store, route.projectId)
        is MobileRoute.Board -> BoardScreen(store, route.boardId)
        is MobileRoute.Conversation -> ConversationScreen(store, card(route.cardId), openUrl)
        is MobileRoute.Channel -> ChannelScreen(store, route.projectId, openUrl)
        is MobileRoute.MailMessage -> MailMessageScreen(store, route, openUrl)
        is MobileRoute.Pane -> CardPaneScreen(store, card(route.cardId), route.pane, openUrl)
        is MobileRoute.Tool -> ToolScreen(store, route)
        is MobileRoute.NewTask -> CreationScreen(store, route.chat)
        is MobileRoute.ShareTarget -> ShareTargetScreen(store, route.chat)
        is MobileRoute.FilePath ->
            FilesScreen(store, inConversation = route.cardId.isNotEmpty(), route = route)
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
