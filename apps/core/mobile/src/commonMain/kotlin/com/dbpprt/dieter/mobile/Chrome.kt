@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/** A toolbar or menu command. iOS renders it as a bar button or UIMenu element. */
@Immutable
internal class ChromeAction(
    val id: String,
    val title: String,
    val glyph: Glyph? = null,
    val enabled: Boolean = true,
    val destructive: Boolean = false,
    val checked: Boolean = false,
    /** Non-empty actions open a menu instead of running [onClick]. */
    val menu: List<MenuSection> = emptyList(),
    val subtitle: String = "",
    val onClick: () -> Unit = {},
) {
    /** Structural identity, so native bars rebuild only when something visible changed. */
    val signature: String
        get() =
            "$id|$title|${glyph?.name}|$enabled|$destructive|$checked|$subtitle[" +
                menu.joinToString(";") { it.signature } +
                "]"
}

@Immutable
internal class MenuSection(
    val actions: List<ChromeAction>,
    val title: String = "",
    /** Inline sections render with separators; otherwise as a nested submenu. */
    val inline: Boolean = true,
    val glyph: Glyph? = null,
) {
    val signature: String
        get() = "$title|$inline|${glyph?.name}:" + actions.joinToString(",") { it.signature }
}

/** Everything a platform needs to draw a screen's bars. */
@Immutable
internal class ScreenChrome(
    val title: String,
    val subtitle: String = "",
    /** Root screens use iOS large titles and Material large flexible app bars. */
    val large: Boolean = false,
    val actions: List<ChromeAction> = emptyList(),
    /** Main creation command: an iOS trailing bar button, an Android floating action button. */
    val primary: ChromeAction? = null,
    /** Modal confirmation, e.g. Start. Prominent on iOS; a top bar button on Android. */
    val confirm: ChromeAction? = null,
    /** Modal dismissal. iOS shows a close button; Android a navigation close icon. */
    val cancel: ChromeAction? = null,
) {
    val signature: String
        get() =
            listOf(
                    title,
                    subtitle,
                    large.toString(),
                    actions.joinToString("/") { it.signature },
                    primary?.signature.orEmpty(),
                    confirm?.signature.orEmpty(),
                    cancel?.signature.orEmpty(),
                )
                .joinToString("‖")
}

/** Implemented by the iOS host for each native navigation item. */
internal interface ChromeHost {
    fun publish(chrome: ScreenChrome)

    fun titleCollapsed(collapsed: Boolean)
}

internal val LocalChromeHost = staticCompositionLocalOf<ChromeHost?> { null }

/** Android back affordance for pushed screens; null on roots and in side-by-side panes. */
internal val LocalBackAction = staticCompositionLocalOf<(() -> Unit)?> { null }

/** Insets the Android host leaves for each screen (status/navigation bars, cutouts). */
internal val LocalScreenInsets = staticCompositionLocalOf { WindowInsets(0, 0, 0, 0) }

/** True beside a navigation rail, whose own button already starts new tasks and chats. */
internal val LocalRailCreates = staticCompositionLocalOf { false }

internal val LocalMobileStore = staticCompositionLocalOf<MobileStore?> { null }

@Stable
internal class ScreenScope(
    val padding: PaddingValues,
    val listState: LazyListState,
    private val chrome: ScreenChrome,
    private val showsLargeTitle: Boolean,
) {
    /** Adds the iOS large title as the first list item. Android draws it in the app bar. */
    fun LazyListScope.titleHeader() {
        if (showsLargeTitle)
            item(key = "large-title", contentType = "large-title") {
                LargeTitle(chrome.title, chrome.subtitle)
            }
    }
}

@Composable
private fun LargeTitle(title: String, subtitle: String) {
    Column(
        Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 2.dp, bottom = 10.dp)
    ) {
        Text(
            title,
            style = type.largeTitle,
            color = palette.label,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        if (subtitle.isNotEmpty())
            Text(
                subtitle,
                style = type.subheadline,
                color = palette.secondaryLabel,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
    }
}

/**
 * A screen with platform bars. On iOS the chrome is published to the native navigation item and
 * content scrolls beneath the Liquid Glass bars; on Android a Material 3 scaffold draws app bars
 * that collapse with the content and a floating action button for [ScreenChrome.primary].
 */
@Composable
internal fun Screen(
    chrome: ScreenChrome,
    modifier: Modifier = Modifier,
    listState: LazyListState = rememberLazyListState(),
    bottomBar: (@Composable () -> Unit)? = null,
    content: @Composable ScreenScope.() -> Unit,
) {
    val host = LocalChromeHost.current
    if (host != null) {
        AppleScreen(host, chrome, modifier, listState, bottomBar, content)
        return
    }
    MaterialScreen(chrome, modifier, listState, bottomBar, content)
}

@Composable
private fun AppleScreen(
    host: ChromeHost,
    chrome: ScreenChrome,
    modifier: Modifier,
    listState: LazyListState,
    bottomBar: (@Composable () -> Unit)?,
    content: @Composable ScreenScope.() -> Unit,
) {
    SideEffect { host.publish(chrome) }
    val threshold = with(LocalDensity.current) { 34.dp.roundToPx() }
    val collapsed by
        remember(chrome.large) {
            derivedStateOf {
                !chrome.large ||
                    listState.firstVisibleItemIndex > 0 ||
                    listState.firstVisibleItemScrollOffset > threshold
            }
        }
    LaunchedEffect(host, collapsed) { host.titleCollapsed(collapsed) }
    val insets = WindowInsets.safeDrawing.only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal)
    val bottomInsets = WindowInsets.safeDrawing.only(WindowInsetsSides.Bottom)
    val density = LocalDensity.current
    Box(modifier.fillMaxSize().background(palette.background)) {
        // Backgrounds run edge to edge; content stays clear of the iPad sidebar, neighbouring
        // split-view columns and the iPhone's landscape notch, which UIKit reports as safe area.
        Column(
            Modifier.fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal))
        ) {
            Box(Modifier.weight(1f)) {
                val top = insets.asPaddingValues()
                val bottom =
                    if (bottomBar == null) bottomInsets.asPaddingValues().calculateBottomPadding()
                    else 0.dp
                ScreenScope(
                        PaddingValues(
                            top = top.calculateTopPadding(),
                            bottom = bottom + 12.dp,
                        ),
                        listState,
                        chrome,
                        chrome.large,
                    )
                    .content()
            }
            if (bottomBar != null) bottomBar()
        }
        // iOS 26 softens content beneath glass bars; Compose content is not a UIScrollView.
        val fade = with(density) { insets.getTop(this).toDp() } + 6.dp
        Box(
            Modifier.fillMaxWidth()
                .height(fade)
                .background(
                    Brush.verticalGradient(
                        0f to palette.background,
                        .72f to palette.background.copy(alpha = .86f),
                        1f to palette.background.copy(alpha = 0f),
                    )
                )
        )
    }
}

@Composable
private fun MaterialScreen(
    chrome: ScreenChrome,
    modifier: Modifier,
    listState: LazyListState,
    bottomBar: (@Composable () -> Unit)?,
    content: @Composable ScreenScope.() -> Unit,
) {
    val behavior =
        if (chrome.large) TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
        else TopAppBarDefaults.pinnedScrollBehavior()
    val back = LocalBackAction.current
    val insets = LocalScreenInsets.current
    val fab = chrome.primary.takeUnless { LocalRailCreates.current }
    val barColors =
        TopAppBarDefaults.topAppBarColors(
            containerColor = palette.background,
            scrolledContainerColor = colors.surfaceContainer,
        )
    val navigation: @Composable () -> Unit = {
        when {
            chrome.cancel != null ->
                IconButton(chrome.cancel.onClick, Modifier.testTag("chrome-${chrome.cancel.id}")) {
                    Icon(Glyph.CLOSE, chrome.cancel.title, size = 24.dp)
                }
            back != null ->
                IconButton(back, Modifier.testTag("chrome-back")) {
                    Icon(Glyph.BACK, "Back", size = 24.dp)
                }
        }
    }
    val actions: @Composable RowScope.() -> Unit = { MaterialActions(chrome) }
    Scaffold(
        modifier.nestedScroll(behavior.nestedScrollConnection),
        containerColor = palette.background,
        contentWindowInsets = insets.only(WindowInsetsSides.Bottom + WindowInsetsSides.Horizontal),
        topBar = {
            val subtitle: (@Composable () -> Unit)? =
                chrome.subtitle
                    .takeIf { it.isNotEmpty() }
                    ?.let { { Text(it, maxLines = 1, overflow = TextOverflow.Ellipsis) } }
            val barInsets = insets.only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal)
            val title: @Composable () -> Unit = {
                Column {
                    Text(
                        chrome.title,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        style =
                            if (chrome.large) LocalTextStyle.current
                            else
                                MaterialTheme.typography.titleLarge.copy(
                                    fontWeight = FontWeight.Medium
                                ),
                    )
                    if (subtitle != null)
                        CompositionLocalProvider(
                            LocalTextStyle provides MaterialTheme.typography.bodyMedium,
                            LocalContentColor provides colors.onSurfaceVariant,
                        ) {
                            subtitle()
                        }
                }
            }
            if (chrome.large)
                LargeTopAppBar(
                    title = title,
                    navigationIcon = navigation,
                    actions = actions,
                    windowInsets = barInsets,
                    colors = barColors,
                    scrollBehavior = behavior,
                )
            else
                TopAppBar(
                    title = title,
                    navigationIcon = navigation,
                    actions = actions,
                    windowInsets = barInsets,
                    colors = barColors,
                    scrollBehavior = behavior,
                )
        },
        bottomBar = bottomBar ?: {},
        floatingActionButton = {
            fab?.let { primary ->
                val expanded by remember { derivedStateOf { listState.firstVisibleItemIndex == 0 } }
                ExtendedFloatingActionButton(
                    text = { Text(primary.title) },
                    icon = { Icon(primary.glyph ?: Glyph.ADD, null, size = 24.dp) },
                    onClick = primary.onClick,
                    expanded = expanded,
                    modifier = Modifier.testTag("chrome-${primary.id}"),
                )
            }
        },
    ) { padding ->
        ScreenScope(
                PaddingValues(
                    top = padding.calculateTopPadding(),
                    bottom = padding.calculateBottomPadding() + if (fab != null) 88.dp else 16.dp,
                ),
                listState,
                chrome,
                false,
            )
            .content()
    }
}

/** Up to two icon actions, the rest in an overflow menu, as Material top app bars do. */
@Composable
private fun RowScope.MaterialActions(chrome: ScreenChrome) {
    chrome.confirm?.let { confirm ->
        Button(
            onClick = confirm.onClick,
            enabled = confirm.enabled,
            modifier = Modifier.padding(end = 8.dp).testTag("chrome-${confirm.id}"),
        ) {
            Text(confirm.title)
        }
    }
    val visible = chrome.actions.filter { it.glyph != null }.take(2)
    val overflow = chrome.actions - visible.toSet()
    visible.forEach { action -> ActionButton(action) }
    if (overflow.isNotEmpty())
        ActionButton(
            ChromeAction(
                "overflow",
                "More options",
                Glyph.MORE,
                menu =
                    overflow.map {
                        if (it.menu.isEmpty()) MenuSection(listOf(it))
                        else
                            MenuSection(
                                it.menu.flatMap { section -> section.actions },
                                it.title,
                                inline = false,
                                glyph = it.glyph,
                            )
                    },
            )
        )
}

@Composable
private fun ActionButton(action: ChromeAction) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(
            onClick = { if (action.menu.isNotEmpty()) open = true else action.onClick() },
            enabled = action.enabled,
            modifier = Modifier.testTag("chrome-${action.id}"),
        ) {
            Icon(
                (action.glyph ?: Glyph.MORE).let {
                    if (it == Glyph.MORE_HORIZONTAL) Glyph.MORE else it
                },
                action.title,
                size = 24.dp,
            )
        }
        if (action.menu.isNotEmpty()) MaterialMenu(action.menu, open) { open = false }
    }
}

/** Material dropdown with sections, checkmarks and nested submenus. */
@Composable
internal fun MaterialMenu(sections: List<MenuSection>, expanded: Boolean, onDismiss: () -> Unit) {
    var nested by remember { mutableStateOf<MenuSection?>(null) }
    DropdownMenu(
        expanded,
        {
            nested = null
            onDismiss()
        },
        shape = MaterialTheme.shapes.large,
        containerColor = colors.surfaceContainer,
    ) {
        val shown = nested?.let { listOf(MenuSection(it.actions, it.title)) } ?: sections
        nested?.let { section ->
            DropdownMenuItem(
                text = { Text(section.title, style = MaterialTheme.typography.labelLarge) },
                leadingIcon = { Icon(Glyph.BACK, "Back", size = 20.dp) },
                onClick = { nested = null },
            )
            HorizontalDivider()
        }
        shown.forEachIndexed { index, section ->
            if (index > 0) HorizontalDivider(Modifier.padding(vertical = 4.dp))
            if (section.title.isNotEmpty() && section.inline && nested == null)
                Text(
                    section.title,
                    Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    style = MaterialTheme.typography.labelMedium,
                    color = colors.onSurfaceVariant,
                )
            if (!section.inline && nested == null)
                DropdownMenuItem(
                    text = { Text(section.title) },
                    leadingIcon = section.glyph?.let { { Icon(it, null, size = 22.dp) } },
                    trailingIcon = { Icon(Glyph.CHEVRON_RIGHT, null, size = 20.dp) },
                    onClick = { nested = section },
                )
            else
                section.actions.forEach { action ->
                    DropdownMenuItem(
                        text = {
                            Column {
                                Text(
                                    action.title,
                                    color =
                                        if (action.destructive) colors.error else colors.onSurface,
                                )
                                if (action.subtitle.isNotEmpty())
                                    Text(
                                        action.subtitle,
                                        style = MaterialTheme.typography.bodySmall,
                                        color = colors.onSurfaceVariant,
                                    )
                            }
                        },
                        leadingIcon =
                            when {
                                action.checked -> {
                                    { Icon(Glyph.CHECK, "Selected", size = 22.dp) }
                                }
                                action.glyph != null -> {
                                    {
                                        Icon(
                                            action.glyph,
                                            null,
                                            tint =
                                                if (action.destructive) colors.error
                                                else colors.onSurfaceVariant,
                                            size = 22.dp,
                                        )
                                    }
                                }
                                else -> null
                            },
                        trailingIcon =
                            if (action.menu.isNotEmpty()) {
                                { Icon(Glyph.CHEVRON_RIGHT, null, size = 20.dp) }
                            } else null,
                        enabled = action.enabled,
                        onClick = {
                            if (action.menu.isNotEmpty())
                                nested =
                                    MenuSection(action.menu.flatMap { it.actions }, action.title)
                            else {
                                nested = null
                                onDismiss()
                                action.onClick()
                            }
                        },
                        modifier = Modifier.testTag("menu-${action.id}"),
                    )
                }
        }
    }
}

/** Shows the screen-level connection notice. */
@Composable
internal fun ConnectionNotice(store: MobileStore, modifier: Modifier = Modifier) {
    val session by store.session.collectAsState()
    session.notice?.let { notice ->
        Banner(
            notice.title,
            notice.detail,
            modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
            tone = Tone.WARNING,
            glyph = Glyph.OFFLINE,
            actionLabel = "Retry",
            onAction = store::retry,
        )
    }
}

/** Centers content and limits its width on tablets, as readable-width layouts do. */
internal fun Modifier.readableWidth() = this.widthIn(max = 720.dp)

@Composable
internal fun CenteredColumn(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    Box(modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
        Column(Modifier.readableWidth().fillMaxWidth(), content = content)
    }
}
