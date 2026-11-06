package com.getdieter.mobile.desktop

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.key.*
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.platform.exposingTestTags

/**
 * Receives what a screen publishes for its bars, so the desktop pane that hosts it draws them in
 * its own title band. Handlers stay current on every recomposition; the band redraws only when
 * something visible changed.
 */
@Stable
internal class DesktopChromeHost : ChromeHost {
    var chrome by mutableStateOf<ScreenChrome?>(null)
        private set

    private val handlers = mutableMapOf<String, () -> Unit>()

    override fun publish(chrome: ScreenChrome) {
        handlers.clear()
        fun register(action: ChromeAction) {
            handlers[action.id] = action.onClick
            action.menu.forEach { section -> section.actions.forEach(::register) }
        }
        (chrome.actions + listOfNotNull(chrome.primary, chrome.confirm, chrome.cancel)).forEach(
            ::register
        )
        chrome.titleMenu.forEach { section -> section.actions.forEach(::register) }
        if (this.chrome?.signature != chrome.signature) this.chrome = chrome
    }

    override fun titleCollapsed(collapsed: Boolean) = Unit

    /** Runs the screen's latest handler for [action]. */
    fun run(action: ChromeAction) = (handlers[action.id] ?: action.onClick).invoke()

    /** [sections] with every action bound to the latest handler. */
    fun current(sections: List<MenuSection>): List<MenuSection> = sections.map { section ->
        MenuSection(section.actions.map(::current), section.title, section.inline, section.glyph)
    }

    private fun current(action: ChromeAction): ChromeAction =
        ChromeAction(
            action.id,
            action.title,
            action.glyph,
            action.enabled,
            action.destructive,
            action.checked,
            current(action.menu),
            action.subtitle,
            action.value,
        ) {
            run(action)
        }
}

/** A screen inside a desktop pane: its bars go to [host]; its content fills the pane. */
@Composable
internal fun DesktopScreen(
    host: DesktopChromeHost,
    chrome: ScreenChrome,
    modifier: Modifier,
    listState: LazyListState,
    bottomBar: (@Composable () -> Unit)?,
    content: @Composable ScreenScope.() -> Unit,
) {
    SideEffect { host.publish(chrome) }
    Column(modifier.fillMaxSize().background(palette.background)) {
        Box(Modifier.weight(1f)) {
            ScreenScope(PaddingValues(top = 2.dp, bottom = 12.dp), listState, chrome, false)
                .content()
        }
        if (bottomBar != null) bottomBar()
    }
}

/**
 * A pane's title band: back, the title (a menu when the screen offers choices), its actions, and
 * the main command as a blue capsule. [leading] and [trailing] add pane controls.
 */
@Composable
internal fun DesktopTitleBand(
    chrome: ScreenChrome?,
    host: DesktopChromeHost?,
    modifier: Modifier = Modifier,
    back: (() -> Unit)? = null,
    close: (() -> Unit)? = null,
    fallbackTitle: String = "",
    showPrimary: Boolean = true,
    leading: @Composable RowScope.() -> Unit = {},
    trailing: @Composable RowScope.() -> Unit = {},
) {
    fun bound(action: ChromeAction): () -> Unit = { host?.run(action) ?: action.onClick() }
    Row(
        modifier
            .fillMaxWidth()
            .height(DesktopMetrics.titleBand)
            .padding(start = 12.dp, end = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (back != null)
            DesktopIconButton(Glyph.BACK, "Back", back, Modifier.testTag("chrome-back"))
        leading()
        val title = chrome?.title?.ifEmpty { null } ?: fallbackTitle
        val menu = chrome?.titleMenu.orEmpty()
        Column(Modifier.weight(1f).padding(start = 2.dp)) {
            if (menu.isEmpty())
                Text(
                    title,
                    color = tokens.text,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.testTag("desktop-title"),
                )
            else {
                val state = rememberMenuState()
                MenuAnchor(state) {
                    Row(
                        Modifier.desktopClickable(
                                { state.show(host?.current(menu) ?: menu) },
                                RoundedCornerShape(6.dp),
                            )
                            .padding(horizontal = 4.dp, vertical = 2.dp)
                            .testTag("chrome-title-menu"),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            title,
                            color = tokens.text,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                        )
                        Spacer(Modifier.width(4.dp))
                        Icon(
                            Glyph.CHEVRON_DOWN,
                            "Choose",
                            tint = tokens.tertiary,
                            size = 12.dp,
                            weight = GlyphWeight.BOLD,
                        )
                    }
                }
            }
            chrome
                ?.subtitle
                ?.takeIf { it.isNotEmpty() }
                ?.let {
                    Text(
                        it,
                        color = tokens.tertiary,
                        fontSize = 11.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
        }
        chrome?.actions?.forEach { action -> DesktopChromeButton(action, host) }
        trailing()
        chrome?.cancel?.let {
            DesktopCapsule(it.title, bound(it), Modifier.testTag("chrome-${it.id}"))
        }
        chrome?.confirm?.let {
            DesktopCapsule(
                it.title,
                bound(it),
                Modifier.testTag("chrome-${it.id}"),
                prominent = true,
                enabled = it.enabled,
            )
        }
        if (showPrimary)
            chrome?.primary?.let {
                DesktopCapsule(
                    it.title,
                    bound(it),
                    Modifier.testTag("chrome-${it.id}"),
                    glyph = Glyph.ADD,
                    prominent = true,
                    enabled = it.enabled,
                )
            }
        if (close != null)
            DesktopIconButton(Glyph.CLOSE, "Close", close, Modifier.testTag("desktop-close"))
    }
}

/** One toolbar action: an icon button, or a text capsule without a glyph; menus drop down. */
@Composable
internal fun DesktopChromeButton(action: ChromeAction, host: DesktopChromeHost?) {
    val state = rememberMenuState()
    val open = {
        if (action.menu.isNotEmpty()) state.show(host?.current(action.menu) ?: action.menu)
        else host?.run(action) ?: action.onClick()
    }
    MenuAnchor(state) {
        val glyph = action.glyph
        if (glyph == null)
            DesktopCapsule(
                action.title,
                open,
                Modifier.testTag("chrome-${action.id}"),
                enabled = action.enabled,
            )
        else
            DesktopIconButton(
                if (glyph == Glyph.MORE) Glyph.MORE_HORIZONTAL else glyph,
                action.title,
                open,
                Modifier.testTag("chrome-${action.id}"),
                active = action.checked,
                enabled = action.enabled,
            )
    }
}

/** A compact menu: 28 dp rows, checkmarks, values and nested submenus. */
@Composable
internal fun DesktopMenu(sections: List<MenuSection>, expanded: Boolean, onDismiss: () -> Unit) {
    var nested by remember { mutableStateOf<MenuSection?>(null) }
    DropdownMenu(
        expanded,
        {
            nested = null
            onDismiss()
        },
        modifier = Modifier.exposingTestTags().widthIn(min = 200.dp, max = 320.dp),
        offset = DpOffset(0.dp, 4.dp),
        shape = RoundedCornerShape(10.dp),
        containerColor = tokens.panel,
        tonalElevation = 0.dp,
        shadowElevation = 8.dp,
        border = androidx.compose.foundation.BorderStroke(1.dp, tokens.panelRim),
    ) {
        val shown = nested?.let { listOf(MenuSection(it.actions, it.title)) } ?: sections
        nested?.let { section ->
            MenuRow(section.title, Glyph.BACK, onClick = { nested = null }, bold = true)
            MenuDivider()
        }
        shown.forEachIndexed { index, section ->
            if (index > 0) MenuDivider()
            if (section.title.isNotEmpty() && section.inline && nested == null)
                Text(
                    section.title,
                    Modifier.padding(start = 14.dp, end = 14.dp, top = 4.dp, bottom = 2.dp),
                    color = tokens.tertiary,
                    fontSize = 10.5.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            if (!section.inline && nested == null)
                MenuRow(
                    section.title,
                    section.glyph,
                    chevron = true,
                    onClick = { nested = section },
                )
            else
                section.actions.forEach { action ->
                    MenuRow(
                        action.title,
                        action.glyph,
                        Modifier.testTag("menu-${action.id}"),
                        subtitle = action.subtitle,
                        value = action.value,
                        checked = action.checked,
                        destructive = action.destructive,
                        enabled = action.enabled,
                        chevron = action.menu.isNotEmpty(),
                    ) {
                        if (action.menu.isNotEmpty())
                            nested = MenuSection(action.menu.flatMap { it.actions }, action.title)
                        else {
                            nested = null
                            onDismiss()
                            action.onClick()
                        }
                    }
                }
        }
    }
}

@Composable
private fun MenuDivider() =
    HorizontalDivider(Modifier.padding(vertical = 4.dp, horizontal = 8.dp), color = tokens.hairline)

@Composable
private fun MenuRow(
    title: String,
    glyph: Glyph?,
    modifier: Modifier = Modifier,
    subtitle: String = "",
    value: String = "",
    checked: Boolean = false,
    destructive: Boolean = false,
    enabled: Boolean = true,
    chevron: Boolean = false,
    bold: Boolean = false,
    onClick: () -> Unit,
) {
    val color =
        when {
            !enabled -> tokens.tertiary
            destructive -> tokens.offline
            else -> tokens.text
        }
    Row(
        modifier
            .fillMaxWidth()
            .padding(horizontal = 5.dp)
            .heightIn(min = 28.dp)
            .desktopClickable(
                onClick,
                RoundedCornerShape(6.dp),
                hover = tokens.selection,
                enabled = enabled,
            )
            .padding(horizontal = 9.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.width(18.dp), contentAlignment = Alignment.CenterStart) {
            when {
                checked ->
                    Icon(
                        Glyph.CHECK,
                        "Selected",
                        tint = tokens.action,
                        size = 13.dp,
                        weight = GlyphWeight.BOLD,
                    )
                glyph != null ->
                    Icon(
                        glyph,
                        null,
                        tint = if (destructive) tokens.offline else tokens.subtle,
                        size = 14.dp,
                    )
            }
        }
        Spacer(Modifier.width(6.dp))
        Column(Modifier.weight(1f)) {
            Text(
                title,
                color = color,
                fontSize = 12.5.sp,
                fontWeight = if (bold) FontWeight.SemiBold else FontWeight.Normal,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (subtitle.isNotEmpty())
                Text(subtitle, color = tokens.tertiary, fontSize = 10.5.sp, maxLines = 1)
        }
        if (value.isNotEmpty())
            Text(value, Modifier.padding(start = 8.dp), color = tokens.tertiary, fontSize = 11.sp)
        if (chevron)
            Icon(
                Glyph.CHEVRON_RIGHT,
                null,
                Modifier.padding(start = 6.dp),
                tint = tokens.tertiary,
                size = 12.dp,
            )
    }
}

/**
 * A sheet on the desktop: a centered panel above a scrim, with a title band, the confirmation and
 * Esc to close.
 */
@Composable
internal fun DesktopDialog(
    title: String,
    onDismiss: () -> Unit,
    wide: Boolean,
    confirm: ChromeAction?,
    scrollable: Boolean,
    content: @Composable ColumnScope.() -> Unit,
) {
    Dialog(onDismiss, DialogProperties(usePlatformDefaultWidth = false)) {
        DesktopPanel(
            Modifier.exposingTestTags()
                .widthIn(max = if (wide) 760.dp else 560.dp)
                .fillMaxWidth(.92f)
                .heightIn(max = 720.dp)
                .onPreviewKeyEvent {
                    if (it.type == KeyEventType.KeyDown && it.key == Key.Escape) {
                        onDismiss()
                        true
                    } else false
                },
            radius = 14.dp,
        ) {
            Column {
                Row(
                    Modifier.fillMaxWidth().height(48.dp).padding(start = 16.dp, end = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        title,
                        Modifier.weight(1f),
                        color = tokens.text,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                    )
                    confirm?.let {
                        DesktopCapsule(
                            it.title,
                            it.onClick,
                            Modifier.testTag("sheet-${it.id}"),
                            prominent = true,
                            enabled = it.enabled,
                        )
                    }
                    DesktopIconButton(
                        Glyph.CLOSE,
                        "Close",
                        onDismiss,
                        Modifier.testTag("sheet-close"),
                    )
                }
                HorizontalDivider(color = tokens.hairline)
                Column(
                    Modifier.fillMaxWidth()
                        .then(
                            if (scrollable) Modifier.verticalScroll(rememberScrollState())
                            else Modifier.weight(1f, fill = false)
                        )
                        .padding(vertical = 8.dp),
                    content = content,
                )
            }
        }
    }
}

/** A thin rule between a pane's title band and its content. */
@Composable
internal fun BandRule() = Box(Modifier.fillMaxWidth().height(1.dp).background(tokens.hairline))
