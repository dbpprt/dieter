package com.getdieter.mobile.desktop

import androidx.compose.animation.*
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.SaveableStateHolder
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.*
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.SessionSlice
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.platform.SystemBackHandler
import com.getdieter.mobile.store.*

/**
 * Lets the host hand hardware-keyboard shortcuts to the desktop shell when no composable has focus
 * to receive them; Android calls [handle] for keys no view handled.
 */
class DesktopKeys {
    internal var handler: ((KeyEvent) -> Boolean)? = null

    fun handle(event: KeyEvent): Boolean = handler?.invoke(event) ?: false
}

/** The desktop shell's keyboard commands. Ctrl (or Meta) chords, as desktop Android uses. */
enum class DesktopShortcut(val keys: String) {
    PALETTE("Ctrl+K"),
    NEW_TASK("Ctrl+N"),
    NEW_CHAT("Ctrl+Shift+N"),
    INBOX("Ctrl+1"),
    MAIL("Ctrl+2"),
    CHANNELS("Ctrl+3"),
    CHATS("Ctrl+4"),
    TERMINALS("Ctrl+5"),
    SETTINGS("Ctrl+,"),
    SIDEBAR("Ctrl+B"),
    REFRESH("Ctrl+R"),
    CLOSE("Ctrl+W"),
    BACK("Alt+←"),
    ESCAPE("Esc");

    companion object {
        /** The command a key press means, or null. Only key-down events count. */
        fun of(key: Key, ctrl: Boolean, shift: Boolean, alt: Boolean): DesktopShortcut? =
            when {
                key == Key.Escape && !ctrl && !alt -> ESCAPE
                alt && !ctrl && key == Key.DirectionLeft -> BACK
                !ctrl || alt -> null
                key == Key.K -> PALETTE
                key == Key.N -> if (shift) NEW_CHAT else NEW_TASK
                shift -> null
                key == Key.One || key == Key.NumPad1 -> INBOX
                key == Key.Two || key == Key.NumPad2 -> MAIL
                key == Key.Three || key == Key.NumPad3 -> CHANNELS
                key == Key.Four || key == Key.NumPad4 -> CHATS
                key == Key.Five || key == Key.NumPad5 -> TERMINALS
                key == Key.Comma -> SETTINGS
                key == Key.B -> SIDEBAR
                key == Key.R -> REFRESH
                key == Key.W -> CLOSE
                else -> null
            }

        fun of(event: KeyEvent): DesktopShortcut? =
            if (event.type != KeyEventType.KeyDown) null
            else
                of(
                    event.key,
                    event.isCtrlPressed || event.isMetaPressed,
                    event.isShiftPressed,
                    event.isAltPressed,
                )
    }
}

/** Desktop-only state that is not navigation: the palette and the floating sidebar. */
@Stable
internal class DesktopState {
    var palette by mutableStateOf(false)
    /** The sidebar floats open above a narrow window. */
    var floatingSidebar by mutableStateOf(false)
}

/**
 * The desktop shell, after the Mac app: a floating sidebar of destinations and projects beside a
 * workspace of panes, each with its own compact title band. Navigation stays the store's, so scopes
 * bind as on touch; this only lays them out side by side.
 */
@Composable
internal fun DesktopShell(store: MobileStore, openUrl: (String) -> Unit, keys: DesktopKeys?) {
    val session by store.session.slice.collectAsState()
    val workspace by store.workspace.slice.collectAsState()
    if (
        session.phase == SessionSlice.Phase.PHASE_AUTH_REQUIRED && !workspace.loaded ||
            session.pairing
    ) {
        Box(Modifier.fillMaxSize().background(tokens.canvas), contentAlignment = Alignment.Center) {
            DesktopPanel(Modifier.widthIn(max = 520.dp).fillMaxWidth(.9f).heightIn(max = 640.dp)) {
                CompositionLocalProvider(LocalScreenInsets provides WindowInsets(0, 0, 0, 0)) {
                    SignInContent(store)
                }
            }
        }
        return
    }
    val navigation by store.routes.collectAsState()
    val error by store.error.collectAsState()
    val hidden by store.layout.sidebarHidden.collectAsState()
    val widths by store.layout.desktopWidths.collectAsState()
    val state = remember { DesktopState() }
    val snackbar = remember { SnackbarHostState() }
    val focus = remember { FocusRequester() }
    val place = navigation.desktopPlace()
    LaunchedEffect(error) {
        if (error.isNotEmpty()) {
            snackbar.showSnackbar(error, withDismissAction = true)
            store.error.value = ""
        }
    }
    fun shortcut(value: DesktopShortcut): Boolean {
        when (value) {
            DesktopShortcut.PALETTE -> state.palette = !state.palette
            DesktopShortcut.NEW_TASK -> store.newConversation(chat = false)
            DesktopShortcut.NEW_CHAT -> store.newConversation(chat = true)
            DesktopShortcut.INBOX -> store.openSection(DesktopSection.INBOX)
            DesktopShortcut.MAIL -> store.openSection(DesktopSection.MAIL)
            DesktopShortcut.CHANNELS -> store.openSection(DesktopSection.CHANNELS)
            DesktopShortcut.CHATS -> store.openSection(DesktopSection.CHATS)
            DesktopShortcut.TERMINALS -> store.openSection(DesktopSection.TERMINALS)
            DesktopShortcut.SETTINGS -> store.openSection(DesktopSection.SETTINGS)
            DesktopShortcut.SIDEBAR ->
                store.layout.setSidebarHidden(!store.layout.sidebarHidden.value)
            DesktopShortcut.REFRESH -> store.session.refresh()
            DesktopShortcut.CLOSE ->
                if (store.routes.value.modal != null) store.dismiss() else store.closeDetail()
            DesktopShortcut.BACK ->
                if (store.routes.value.stack.size > store.routes.value.desktopPlace().base)
                    store.pop()
                else return false
            DesktopShortcut.ESCAPE ->
                when {
                    state.palette -> state.palette = false
                    state.floatingSidebar -> state.floatingSidebar = false
                    store.routes.value.modal != null -> store.dismiss()
                    else -> return false
                }
        }
        return true
    }
    val handler = remember { mutableStateOf<(KeyEvent) -> Boolean>({ false }) }
    handler.value = { event -> DesktopShortcut.of(event)?.let(::shortcut) ?: false }
    DisposableEffect(keys) {
        keys?.handler = { handler.value(it) }
        onDispose { keys?.handler = null }
    }
    SystemBackHandler(
        state.palette ||
            state.floatingSidebar ||
            navigation.modal != null ||
            navigation.stack.size > place.base
    ) {
        when {
            state.palette -> state.palette = false
            state.floatingSidebar -> state.floatingSidebar = false
            navigation.modal != null -> store.dismiss()
            else -> store.pop()
        }
    }
    // Keys reach the shell's shortcuts while nothing inside has focus, e.g. after a sheet closes.
    LaunchedEffect(state.palette, navigation.modal == null) {
        if (!state.palette && navigation.modal == null) runCatching { focus.requestFocus() }
    }
    BoxWithConstraints(
        Modifier.fillMaxSize()
            .background(tokens.canvas)
            .onPreviewKeyEvent { handler.value(it) }
            .focusRequester(focus)
            .focusable()
            .testTag("desktop-shell")
    ) {
        val beside = maxWidth.value >= DesktopLayout.SIDEBAR_BESIDE_DP
        val sidebarShown = !hidden && beside
        var sidebarDrag by remember { mutableStateOf<Float?>(null) }
        val sidebarWidth = sidebarDrag ?: widths.getValue(DesktopPane.SIDEBAR)
        val insets = WindowInsets.safeDrawing.exclude(WindowInsets.ime)
        Row(Modifier.fillMaxSize().windowInsetsPadding(insets)) {
            if (sidebarShown) {
                DesktopSidebar(
                    store,
                    place,
                    onPalette = { state.palette = true },
                    onHide = { store.layout.setSidebarHidden(true) },
                    modifier =
                        Modifier.width(sidebarWidth.dp)
                            .fillMaxHeight()
                            .padding(
                                start = DesktopMetrics.windowInset,
                                top = DesktopMetrics.windowInset,
                                bottom = DesktopMetrics.windowInset,
                            ),
                )
                ResizeHandle(
                    onDrag = {
                        sidebarDrag =
                            DesktopPane.SIDEBAR.clamp(
                                (sidebarDrag ?: widths.getValue(DesktopPane.SIDEBAR)) + it
                            )
                    },
                    onEnd = {
                        sidebarDrag?.let { store.layout.setDesktopWidth(DesktopPane.SIDEBAR, it) }
                        sidebarDrag = null
                    },
                    testTag = "sidebar-resize",
                )
            }
            Box(Modifier.weight(1f).fillMaxHeight()) {
                CompositionLocalProvider(
                    LocalScreenInsets provides WindowInsets(0, 0, 0, 0),
                    LocalRailCreates provides false,
                    LocalSidebarToggle provides
                        if (sidebarShown) null
                        else
                            ({
                                if (beside) store.layout.setSidebarHidden(false)
                                else state.floatingSidebar = true
                            }),
                ) {
                    DesktopWorkspace(
                        store,
                        navigation,
                        place,
                        openUrl,
                        widths,
                        beside = sidebarShown,
                    )
                }
            }
        }
        // A narrow window shows the sidebar above the content.
        AnimatedVisibility(
            !beside && state.floatingSidebar,
            enter = fadeIn(tween(120)),
            exit = fadeOut(tween(120)),
        ) {
            Box(
                Modifier.fillMaxSize().background(Color.Black.copy(.18f)).clickable(
                    remember { MutableInteractionSource() },
                    null,
                ) {
                    state.floatingSidebar = false
                }
            )
        }
        AnimatedVisibility(
            !beside && state.floatingSidebar,
            enter = slideInHorizontally(tween(160)) { -it } + fadeIn(tween(120)),
            exit = slideOutHorizontally(tween(140)) { -it } + fadeOut(tween(120)),
        ) {
            DesktopSidebar(
                store,
                place,
                onPalette = {
                    state.floatingSidebar = false
                    state.palette = true
                },
                onHide = { state.floatingSidebar = false },
                onNavigate = { state.floatingSidebar = false },
                modifier =
                    Modifier.windowInsetsPadding(insets)
                        .width(DesktopPane.SIDEBAR.default.dp)
                        .fillMaxHeight()
                        .padding(DesktopMetrics.windowInset),
            )
        }
        navigation.modal?.let { modal -> DesktopModal(store, modal, openUrl) }
        if (state.palette) DesktopCommandPalette(store) { state.palette = false }
        SnackbarHost(snackbar, Modifier.align(Alignment.BottomCenter).padding(bottom = 18.dp))
    }
}

/** Shows the sidebar again from a pane's title band while it is hidden. */
internal val LocalSidebarToggle = staticCompositionLocalOf<(() -> Unit)?> { null }

/** The workspace beside the sidebar: the section's list or board and its detail. */
@Composable
private fun DesktopWorkspace(
    store: MobileStore,
    navigation: MobileNavigation,
    place: DesktopPlace,
    openUrl: (String) -> Unit,
    widths: Map<DesktopPane, Float>,
    beside: Boolean,
) {
    val holder = rememberSaveableStateHolder()
    val detail = navigation.desktopDetail(place)
    val inset =
        Modifier.padding(
            start = if (beside) 0.dp else DesktopMetrics.windowInset,
            end = DesktopMetrics.windowInset,
            top = DesktopMetrics.windowInset,
            bottom = DesktopMetrics.windowInset,
        )
    when (place.section) {
        DesktopSection.INBOX ->
            ListDetail(
                store,
                DesktopPane.INBOX,
                widths,
                detail,
                MobileTab.INBOX.emptyDetail,
                holder,
                openUrl,
                inset,
            ) {
                DesktopInbox(store)
            }
        DesktopSection.CHATS ->
            ListDetail(
                store,
                DesktopPane.CHATS,
                widths,
                detail,
                MobileTab.CHATS.emptyDetail,
                holder,
                openUrl,
                inset,
            ) {
                DesktopChats(store)
            }
        DesktopSection.MAIL ->
            ListDetail(
                store,
                DesktopPane.MAIL,
                widths,
                detail,
                MobileTab.MAIL.emptyDetail,
                holder,
                openUrl,
                inset,
            ) {
                RoutePane(store, navigation.stack.first(), holder, openUrl)
            }
        DesktopSection.CHANNELS -> {
            val list =
                navigation.stack.getOrNull(1)?.takeIf { it is MobileRoute.Channels }
                    ?: MobileRoute.Channels
            ListDetail(
                store,
                DesktopPane.CHANNELS,
                widths,
                detail,
                list.emptyDetail(MobileTab.MORE),
                holder,
                openUrl,
                inset,
            ) {
                RoutePane(store, list, holder, openUrl)
            }
        }
        DesktopSection.TERMINALS -> {
            val list =
                navigation.stack.getOrNull(1)?.takeIf { it is MobileRoute.Tool }
                    ?: MobileRoute.Tool(ToolPage.TERMINALS)
            ListDetail(
                store,
                DesktopPane.TOOLS,
                widths,
                detail,
                EmptyDetail(
                    Glyph.TERMINAL,
                    "No terminal open",
                    "Choose a terminal or start a new one.",
                ),
                holder,
                openUrl,
                inset,
            ) {
                RoutePane(store, list, holder, openUrl)
            }
        }
        DesktopSection.FOLDERS -> {
            val list =
                navigation.stack.getOrNull(1)?.takeIf { it is MobileRoute.Tool }
                    ?: MobileRoute.Tool(ToolPage.FOLDERS)
            ListDetail(
                store,
                DesktopPane.TOOLS,
                widths,
                detail,
                list.emptyDetail(MobileTab.MORE),
                holder,
                openUrl,
                inset,
            ) {
                RoutePane(store, list, holder, openUrl)
            }
        }
        DesktopSection.PROJECT ->
            if (place.page == ProjectPage.BOARD)
                DesktopBoard(store, place, detail, widths, holder, openUrl, inset)
            else DesktopPage(store, navigation, place, holder, openUrl, inset)
        else -> DesktopPage(store, navigation, place, holder, openUrl, inset)
    }
}

/** A list on the canvas beside its detail panel, divided by a draggable gap. */
@Composable
private fun ListDetail(
    store: MobileStore,
    pane: DesktopPane,
    widths: Map<DesktopPane, Float>,
    detail: List<MobileRoute>,
    empty: EmptyDetail,
    holder: SaveableStateHolder,
    openUrl: (String) -> Unit,
    modifier: Modifier,
    list: @Composable () -> Unit,
) {
    var dragged by remember(pane) { mutableStateOf<Float?>(null) }
    val width = dragged ?: widths.getValue(pane)
    Row(modifier.fillMaxSize()) {
        Box(Modifier.width(width.dp).fillMaxHeight().testTag("desktop-list")) { list() }
        ResizeHandle(
            onDrag = { dragged = pane.clamp((dragged ?: widths.getValue(pane)) + it) },
            onEnd = {
                dragged?.let { store.layout.setDesktopWidth(pane, it) }
                dragged = null
            },
            testTag = "list-resize",
        )
        DesktopPanel(Modifier.weight(1f).fillMaxHeight().testTag("desktop-detail")) {
            val top = detail.lastOrNull()
            if (top == null)
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    EmptyState(empty.glyph, empty.title, empty.message)
                }
            else DetailPane(store, detail, holder, openUrl)
        }
    }
}

/**
 * What opened from a list or board: a conversation with its tab track, or any other route with its
 * own title band. Back pops within the panel; close returns to the list alone.
 */
@Composable
internal fun DetailPane(
    store: MobileStore,
    detail: List<MobileRoute>,
    holder: SaveableStateHolder,
    openUrl: (String) -> Unit,
) {
    val top = detail.last()
    val conversation = detail.conversationScope()
    if (conversation != null) {
        ConversationPanel(
            store,
            conversation.first,
            conversation.second,
            top,
            detail,
            holder,
            openUrl,
        )
        return
    }
    RoutePane(
        store,
        top,
        holder,
        openUrl,
        back = if (detail.size > 1) store::pop else null,
        close = store::closeDetail,
    )
}

/**
 * One route with a title band drawn from the chrome its screen publishes. The screen's own back
 * affordance is the band's.
 */
@Composable
internal fun RoutePane(
    store: MobileStore,
    route: MobileRoute,
    holder: SaveableStateHolder,
    openUrl: (String) -> Unit,
    back: (() -> Unit)? = null,
    close: (() -> Unit)? = null,
    band: Boolean = true,
) {
    val host = remember(route.key) { DesktopChromeHost() }
    Column(Modifier.fillMaxSize()) {
        if (band) {
            val toggle = LocalSidebarToggle.current
            DesktopTitleBand(
                host.chrome,
                host,
                back = back,
                close = close,
                leading = {
                    if (toggle != null && back == null && close == null)
                        DesktopIconButton(
                            Glyph.LIST,
                            "Show sidebar",
                            toggle,
                            Modifier.testTag("sidebar-show"),
                            tooltip = "Show sidebar (Ctrl+B)",
                        )
                },
            )
        }
        Box(Modifier.weight(1f).fillMaxWidth()) {
            CompositionLocalProvider(LocalChromeHost provides host, LocalBackAction provides null) {
                holder.SaveableStateProvider(route.key) { RouteContent(store, route, openUrl) }
            }
        }
    }
}

/** A page that fills the workspace: settings, devices, usage, a machine or a project tool. */
@Composable
private fun DesktopPage(
    store: MobileStore,
    navigation: MobileNavigation,
    place: DesktopPlace,
    holder: SaveableStateHolder,
    openUrl: (String) -> Unit,
    modifier: Modifier,
) {
    val top = navigation.stack.last()
    // Settings-like pages keep a readable width; tools use the whole panel.
    val readable =
        place.section in
            setOf(
                DesktopSection.SETTINGS,
                DesktopSection.DEVICES,
                DesktopSection.USAGE,
                DesktopSection.PLACES,
            )
    DesktopPanel(modifier.fillMaxSize().testTag("desktop-page")) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
            Box(
                if (readable) Modifier.widthIn(max = 820.dp).fillMaxHeight()
                else Modifier.fillMaxSize()
            ) {
                RoutePane(
                    store,
                    top,
                    holder,
                    openUrl,
                    back = if (navigation.stack.size > place.base) store::pop else null,
                )
            }
        }
    }
}

/** A new task or chat, or a share target, as a centered sheet above the workspace. */
@Composable
private fun DesktopModal(store: MobileStore, route: MobileRoute, openUrl: (String) -> Unit) {
    val holder = rememberSaveableStateHolder()
    Box(
        Modifier.fillMaxSize()
            .background(Color.Black.copy(alpha = if (tokens.dark) .4f else .22f))
            .clickable(remember { MutableInteractionSource() }, null) { store.dismiss() },
        contentAlignment = Alignment.Center,
    ) {
        DesktopPanel(
            Modifier.widthIn(max = 720.dp)
                .fillMaxWidth(.86f)
                .fillMaxHeight(.86f)
                .clickable(remember { MutableInteractionSource() }, null) {}
                .testTag("desktop-modal"),
            radius = 14.dp,
        ) {
            CompositionLocalProvider(LocalSidebarToggle provides null) {
                RoutePane(store, route, holder, openUrl)
            }
        }
    }
}
