@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.getdieter.mobile.app

import androidx.compose.animation.*
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInParent
import androidx.compose.ui.layout.onPlaced
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.getdieter.mobile.design.*
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.store.*
import kotlin.math.abs
import kotlinx.coroutines.launch

/**
 * The current screen's creation command (New task, New chat, …). Screens publish their
 * [ScreenChrome.primary] here instead of drawing a floating action button when the floating
 * navigation shows it as its compose orb; the most recently published live command wins.
 */
@Stable
internal class PrimarySlot {
    private val entries = mutableStateListOf<Pair<Any, ChromeAction>>()

    val current: ChromeAction?
        get() = entries.lastOrNull()?.second

    fun publish(owner: Any, action: ChromeAction) {
        val index = entries.indexOfFirst { it.first === owner }
        if (index < 0) entries.add(owner to action)
        else if (entries[index].second.signature != action.signature)
            entries[index] = owner to action
    }

    fun withdraw(owner: Any) {
        entries.removeAll { it.first === owner }
    }
}

/** Set by the shell while a floating navigation shows the screens' creation command. */
internal val LocalPrimarySlot = staticCompositionLocalOf<PrimarySlot?> { null }

/** Sizes of one navigation style on one axis. */
private class NavMetrics(
    /** The bar's cross-axis size: height at the bottom, width on the side. */
    val thickness: Dp,
    /** Each item's main-axis size on the side; bottom bars share their width. */
    val item: Dp,
    val orb: Dp,
    val labels: Boolean,
) {
    companion object {
        fun of(
            style: NavigationStyle,
            vertical: Boolean,
            compact: Boolean,
            dense: Boolean = false,
        ) =
            when {
                // Short windows (phones and cover screens sideways): icons only, tighter.
                vertical && compact -> NavMetrics(60.dp, 50.dp, 52.dp, labels = false)
                // A narrow list pane: icons only, so five tabs and the orb still fit.
                !vertical && dense && style != NavigationStyle.ISLAND ->
                    NavMetrics(56.dp, 0.dp, 56.dp, labels = false)
                !vertical && dense -> NavMetrics(54.dp, 46.dp, 54.dp, labels = false)
                else -> regular(style, vertical)
            }

        private fun regular(style: NavigationStyle, vertical: Boolean) =
            when (style) {
                NavigationStyle.ISLAND ->
                    if (vertical) NavMetrics(60.dp, 54.dp, 56.dp, labels = false)
                    else NavMetrics(58.dp, 52.dp, 58.dp, labels = false)
                NavigationStyle.LENS ->
                    if (vertical) NavMetrics(68.dp, 62.dp, 60.dp, labels = true)
                    else NavMetrics(62.dp, 0.dp, 62.dp, labels = true)
                else ->
                    if (vertical) NavMetrics(72.dp, 64.dp, 60.dp, labels = true)
                    else NavMetrics(66.dp, 0.dp, 66.dp, labels = true)
            }
    }
}

/** The gap between the floating navigation and the window's edge. */
internal val FloatingMargin = 12.dp

/**
 * What a page beneath the floating navigation keeps clear: the bar and its margins, in height at
 * the bottom or width on the side.
 */
internal fun NavigationStyle.floatingReserve(
    vertical: Boolean,
    compact: Boolean,
    dense: Boolean = false,
): Dp =
    NavMetrics.of(this, vertical, compact, dense).let {
        if (vertical) it.thickness + FloatingMargin + 6.dp
        else maxOf(it.thickness, it.orb) + FloatingMargin + 10.dp
    }

/**
 * The floating liquid glass navigation: a glass bar of the five tabs and, beside it, the current
 * screen's creation command as a tinted glass orb. [vertical] stands it on the leading edge.
 * [minimized] (Lens only) shrinks the bar to the current tab while the page scrolls down.
 */
@Composable
internal fun FloatingNavigation(
    store: MobileStore,
    navigation: MobileNavigation,
    style: NavigationStyle,
    vertical: Boolean,
    compact: Boolean,
    dense: Boolean,
    backdrop: GlassBackdrop?,
    minimized: Boolean,
    moreOpen: Boolean,
    primary: ChromeAction?,
    onSelect: (MobileTab) -> Unit,
    onExpand: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val badge = rememberTabBadges(store)
    val selected = if (moreOpen) MobileTab.MORE else navigation.tab
    val metrics = NavMetrics.of(style, vertical, compact, dense)
    val small = minimized && style == NavigationStyle.LENS && !vertical
    // The orb keeps its last command while it animates away.
    var shown by remember { mutableStateOf(primary) }
    if (primary != null) shown = primary
    val orb: @Composable () -> Unit = {
        AnimatedVisibility(
            primary != null,
            enter = scaleIn(spring(.55f, 420f), initialScale = .4f) + fadeIn(),
            exit = scaleOut(targetScale = .4f) + fadeOut(tween(120)),
        ) {
            shown?.let { PrimaryOrb(it, metrics.orb, backdrop) }
        }
    }
    val bar: @Composable (Modifier) -> Unit = { barModifier ->
        GlassBar(
            style,
            vertical,
            metrics,
            selected,
            small,
            backdrop,
            badge,
            moreOpen,
            onSelect,
            onExpand,
            barModifier,
        )
    }
    if (vertical)
        Column(
            modifier,
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            orb()
            bar(Modifier)
        }
    else
        Row(
            modifier,
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement =
                if (small) Arrangement.SpaceBetween
                else Arrangement.spacedBy(10.dp, Alignment.CenterHorizontally),
        ) {
            bar(
                if (style == NavigationStyle.ISLAND) Modifier else Modifier.weight(1f, fill = false)
            )
            orb()
        }
}

@Composable
private fun GlassBar(
    style: NavigationStyle,
    vertical: Boolean,
    metrics: NavMetrics,
    selected: MobileTab,
    small: Boolean,
    backdrop: GlassBackdrop?,
    badge: (MobileTab) -> String,
    moreOpen: Boolean,
    onSelect: (MobileTab) -> Unit,
    onExpand: () -> Unit,
    modifier: Modifier,
) {
    val shape = RoundedCornerShape(50)
    Box(
        modifier
            .then(
                if (vertical) Modifier.width(metrics.thickness)
                else Modifier.height(metrics.thickness)
            )
            .glass(backdrop, shape, GlassStyles.chrome())
            .testTag("floating-navigation")
    ) {
        AnimatedContent(
            small,
            transitionSpec = {
                fadeIn(tween(180, delayMillis = 70)) togetherWith
                    fadeOut(tween(90)) using
                    SizeTransform(clip = false) { _, _ -> spring(.82f, 420f) }
            },
            contentAlignment = Alignment.CenterStart,
            label = "navigation-size",
        ) { collapsed ->
            if (collapsed)
                Box(
                    Modifier.fillMaxHeight()
                        .padding(5.dp)
                        .clip(CircleShape)
                        .selectable(true, role = Role.Tab, onClick = onExpand)
                        .semantics { contentDescription = "Show all tabs" }
                        .testTag("navigation-expand"),
                    contentAlignment = Alignment.Center,
                ) {
                    val colors = dropColors()
                    Box(
                        Modifier.fillMaxHeight().aspectRatio(1.25f).drawBehind {
                            drawDrop(style, colors, Rect(Offset.Zero, size), 0f, this)
                        },
                        contentAlignment = Alignment.Center,
                    ) {
                        TabIcon(selected, badge(selected), moreOpen, dropTint(style))
                    }
                }
            else
                BarItems(
                    style,
                    vertical,
                    metrics,
                    selected,
                    badge,
                    moreOpen,
                    onSelect,
                    if (style == NavigationStyle.ISLAND) Modifier
                    else if (vertical) Modifier else Modifier.fillMaxWidth(),
                )
        }
    }
}

/** What sits on the selection drop: an accent on the clear lens, on-colors on filled drops. */
@Composable
@ReadOnlyComposable
private fun dropTint(style: NavigationStyle): Color =
    when (style) {
        NavigationStyle.ISLAND -> palette.onAccent
        NavigationStyle.LENS -> palette.accent
        else -> palette.onAccentContainer
    }

/**
 * The tabs over their selection drop. The drop's two edges chase the selected tab on different
 * springs, the leading one quick and the trailing one slow, so it stretches like a liquid and
 * settles with a wobble. Dragging along a Dock or Lens bar lifts the drop under the finger as a
 * lens that magnifies the icons it passes; letting go selects the tab beneath it.
 */
@Composable
private fun BarItems(
    style: NavigationStyle,
    vertical: Boolean,
    metrics: NavMetrics,
    selected: MobileTab,
    badge: (MobileTab) -> String,
    moreOpen: Boolean,
    onSelect: (MobileTab) -> Unit,
    modifier: Modifier,
) {
    val tabs = MobileTab.entries
    val bounds = remember { mutableStateMapOf<MobileTab, Rect>() }
    // The drop's edges along the bar; they animate between tabs when nothing is dragged.
    val start = remember { Animatable(Float.NaN) }
    val end = remember { Animatable(Float.NaN) }
    // While a finger drags the lens: its centre and its fixed span, taken from the tab it
    // started on. The centre stays between the first and last tab, so the lens never leaves.
    var dragCenter by remember { mutableStateOf<Float?>(null) }
    var lensSpan by remember { mutableFloatStateOf(0f) }
    val dragging = dragCenter != null
    var hovered by remember { mutableStateOf<MobileTab?>(null) }
    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current
    val lift by
        animateFloatAsState(
            if (dragging) 1f else 0f,
            spring(dampingRatio = .55f, stiffness = 420f),
            label = "lens-lift",
        )
    val target = bounds[selected]
    LaunchedEffect(target, dragging, vertical) {
        val rect = target ?: return@LaunchedEffect
        if (dragging) return@LaunchedEffect
        val (to0, to1) = if (vertical) rect.top to rect.bottom else rect.left to rect.right
        if (start.value.isNaN()) {
            start.snapTo(to0)
            end.snapTo(to1)
            return@LaunchedEffect
        }
        val forward = to0 > start.value
        val quick = spring<Float>(dampingRatio = .6f, stiffness = 520f)
        val slow = spring<Float>(dampingRatio = .74f, stiffness = 150f)
        launch { start.animateTo(to0, if (forward) slow else quick) }
        launch { end.animateTo(to1, if (forward) quick else slow) }
    }
    fun axis(rect: Rect) = if (vertical) rect.center.y else rect.center.x
    fun span(rect: Rect) = if (vertical) rect.height else rect.width
    fun nearest(position: Float): MobileTab? =
        bounds.entries.minByOrNull { (_, rect) -> abs(axis(rect) - position) }?.key
    /** The drop's edges now: the dragged lens, else the animated drop; null before layout. */
    fun edges(): Pair<Float, Float>? {
        dragCenter?.let { center ->
            return center - lensSpan / 2 to center + lensSpan / 2
        }
        if (start.value.isNaN() || end.value.isNaN()) return null
        return start.value to end.value
    }
    fun follow(position: Float) {
        val centers = bounds.values.map(::axis)
        val center =
            if (centers.isEmpty()) position else position.coerceIn(centers.min(), centers.max())
        dragCenter = center
        val under = nearest(center)
        if (under != hovered) {
            if (hovered != null) haptics.performHapticFeedback(HapticFeedbackType.SegmentTick)
            hovered = under
        }
    }
    /** Ends a drag: the drop takes over from the lens where it is, then springs to its tab. */
    fun release(select: Boolean) {
        val center = dragCenter ?: return
        val tab = nearest(center)
        scope.launch {
            start.snapTo(center - lensSpan / 2)
            end.snapTo(center + lensSpan / 2)
            dragCenter = null
            if (select && tab != null) {
                haptics.performHapticFeedback(HapticFeedbackType.Confirm)
                onSelect(tab)
            }
        }
    }
    val draggable = style != NavigationStyle.ISLAND
    val gestures =
        if (!draggable) Modifier
        else
            Modifier.pointerInput(vertical) {
                val onStart = { offset: Offset ->
                    val position = if (vertical) offset.y else offset.x
                    val under = nearest(position)
                    val rect = under?.let { bounds[it] } ?: target
                    if (rect != null) {
                        lensSpan = span(rect)
                        hovered = under
                        follow(position)
                    }
                }
                val onDrag = { delta: Float -> dragCenter?.let { follow(it + delta) } }
                if (vertical)
                    detectVerticalDragGestures(
                        onDragStart = onStart,
                        onDragEnd = { release(select = true) },
                        onDragCancel = { release(select = false) },
                    ) { change, delta ->
                        change.consume()
                        onDrag(delta)
                    }
                else
                    detectHorizontalDragGestures(
                        onDragStart = onStart,
                        onDragEnd = { release(select = true) },
                        onDragCancel = { release(select = false) },
                    ) { change, delta ->
                        change.consume()
                        onDrag(delta)
                    }
            }
    val colors = dropColors()
    val drop = Modifier.drawBehind {
        val (from, to) = edges() ?: return@drawBehind
        val rect = target ?: return@drawBehind
        val shape =
            if (vertical) Rect(rect.left, from, rect.right, to)
            else Rect(from, rect.top, to, rect.bottom)
        drawDrop(style, colors, shape, 0f, this, alpha = 1f - lift)
    }
    val item: @Composable (MobileTab, Modifier) -> Unit = { tab, itemModifier ->
        val center = bounds[tab]?.let { if (vertical) it.center.y else it.center.x } ?: Float.NaN
        val span = bounds[tab]?.let { if (vertical) it.height else it.width } ?: 1f
        // Icons swell as the lifted lens passes over them.
        val lensEdges = edges()
        val magnify =
            if (lift <= 0f || center.isNaN() || lensEdges == null) 1f
            else {
                val lens = (lensEdges.first + lensEdges.second) / 2
                1f + .08f * lift * (1f - (abs(lens - center) / span)).coerceIn(0f, 1f)
            }
        NavItem(
            tab,
            tab == selected,
            style,
            vertical,
            metrics,
            badge(tab),
            moreOpen,
            magnify,
            onClick = {
                if (tab != selected) haptics.performHapticFeedback(HapticFeedbackType.ContextClick)
                onSelect(tab)
            },
            modifier = itemModifier.onPlaced { bounds[tab] = it.boundsInParent() },
        )
    }
    // The lifted lens is real glass over the tabs: it records them and magnifies what it covers.
    val tabsBackdrop = rememberGlassBackdrop()
    val fill = !vertical && style != NavigationStyle.ISLAND
    Box(
        modifier.then(
            if (vertical) Modifier.padding(vertical = 5.dp)
            else Modifier.fillMaxHeight().padding(horizontal = 5.dp)
        )
    ) {
        val tabsModifier = Modifier.glassSource(tabsBackdrop).then(drop).then(gestures)
        if (vertical)
            Column(
                tabsModifier,
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                tabs.forEach { tab ->
                    item(
                        tab,
                        Modifier.padding(horizontal = 5.dp).fillMaxWidth().height(metrics.item),
                    )
                }
            }
        else
            Row(
                tabsModifier.fillMaxHeight().then(if (fill) Modifier.fillMaxWidth() else Modifier),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement =
                    if (style == NavigationStyle.ISLAND) Arrangement.spacedBy(2.dp)
                    else Arrangement.Start,
            ) {
                tabs.forEach { tab ->
                    item(
                        tab,
                        (if (style == NavigationStyle.ISLAND) Modifier.widthIn(min = metrics.item)
                            else Modifier.weight(1f))
                            .padding(vertical = 5.dp)
                            .fillMaxHeight(),
                    )
                }
            }
        val beadEdges = edges()
        if (draggable && lift > .01f && target != null && beadEdges != null) {
            val density = androidx.compose.ui.platform.LocalDensity.current
            val grow = 8.dp * lift
            val (from, to) = beadEdges
            val rect =
                if (vertical) Rect(target.left, from, target.right, to)
                else Rect(from, target.top, to, target.bottom)
            with(density) {
                Box(
                    Modifier.offset {
                            androidx.compose.ui.unit.IntOffset(
                                (rect.left - grow.toPx() * .6f).toInt(),
                                (rect.top - grow.toPx()).toInt(),
                            )
                        }
                        .size(
                            (rect.width.toDp() + grow * 1.2f),
                            (rect.height.toDp() + grow * 2f),
                        )
                        .graphicsLayer { alpha = lift.coerceIn(0f, 1f) }
                        .glass(tabsBackdrop, CircleShape, GlassStyles.bead())
                )
            }
        }
    }
}

/** The selection drop in [rect]; [lift] (0–1) is how far a drag raised it into a lens. */
private fun drawDrop(
    style: NavigationStyle,
    colors: DropColors,
    rect: Rect,
    lift: Float,
    scope: androidx.compose.ui.graphics.drawscope.DrawScope,
    alpha: Float = 1f,
): Unit =
    with(scope) {
        if (alpha <= 0f) return@with
        if (alpha < 1f) {
            drawContext.canvas.saveLayer(
                androidx.compose.ui.geometry.Rect(Offset.Zero, size),
                androidx.compose.ui.graphics.Paint().apply { this.alpha = alpha },
            )
            drawDrop(style, colors, rect, lift, this)
            drawContext.canvas.restore()
            return@with
        }
        val grow = 7.dp.toPx() * lift
        val shape =
            Rect(
                rect.left - grow * .6f,
                rect.top - grow,
                rect.right + grow * .6f,
                rect.bottom + grow,
            )
        val radius = CornerRadius(shape.minDimension / 2)
        val dark = colors.dark
        when (style) {
            NavigationStyle.ISLAND -> {
                drawRoundRect(colors.accent, shape.topLeft, shape.size, radius)
                drawRoundRect(
                    Brush.verticalGradient(
                        0f to Color.White.copy(alpha = .28f),
                        .55f to Color.Transparent,
                        startY = shape.top,
                        endY = shape.bottom,
                    ),
                    shape.topLeft,
                    shape.size,
                    radius,
                )
            }
            NavigationStyle.LENS -> {
                // A clear drop: a faint body, a bright rim and, lifted, a glassy halo.
                val body =
                    if (dark) Color.White.copy(alpha = .1f + .08f * lift)
                    else Color.Black.copy(alpha = .055f - .03f * lift)
                drawRoundRect(body, shape.topLeft, shape.size, radius)
                if (lift > 0f)
                    drawRoundRect(
                        Color.White.copy(alpha = (if (dark) .1f else .45f) * lift),
                        shape.topLeft,
                        shape.size,
                        radius,
                    )
                drawRoundRect(
                    Brush.linearGradient(
                        0f to Color.White.copy(alpha = if (dark) .5f else 1f),
                        .45f to Color.White.copy(alpha = if (dark) .06f else .25f),
                        1f to Color.White.copy(alpha = if (dark) .3f else .8f),
                        start = shape.topLeft,
                        end = shape.bottomRight,
                    ),
                    shape.topLeft,
                    shape.size,
                    radius,
                    style = Stroke((1.2f + lift).dp.toPx()),
                )
            }
            else -> {
                drawRoundRect(
                    colors.accentContainer.copy(alpha = 1f - .35f * lift),
                    shape.topLeft,
                    shape.size,
                    radius,
                )
                drawRoundRect(
                    Brush.verticalGradient(
                        0f to Color.White.copy(alpha = if (dark) .1f else .5f),
                        .5f to Color.Transparent,
                        startY = shape.top,
                        endY = shape.bottom,
                    ),
                    shape.topLeft,
                    shape.size,
                    radius,
                )
            }
        }
    }

/** Theme colors the drop draws with. */
@Immutable
private class DropColors(val dark: Boolean, val accent: Color, val accentContainer: Color)

@Composable
@ReadOnlyComposable
private fun dropColors() = DropColors(palette.dark, palette.accent, palette.accentContainer)

@Composable
private fun NavItem(
    tab: MobileTab,
    selected: Boolean,
    style: NavigationStyle,
    vertical: Boolean,
    metrics: NavMetrics,
    badge: String,
    moreOpen: Boolean,
    magnify: Float,
    onClick: () -> Unit,
    modifier: Modifier,
) {
    val idle = palette.secondaryLabel
    val active = dropTint(style)
    val tint by
        androidx.compose.animation.animateColorAsState(
            if (selected) active else idle,
            tween(220),
            label = "tab-tint",
        )
    val island = style == NavigationStyle.ISLAND
    // A tab drawn as an icon alone is still named, for TalkBack and device flows.
    val labelled = if (island) selected && !vertical else metrics.labels
    // Not clipped: a badge such as "99+" reaches past the tab's corner. The press ripple is a
    // circle of its own instead.
    Box(
        modifier
            .selectable(
                selected,
                interactionSource = remember { MutableInteractionSource() },
                indication = androidx.compose.material3.ripple(bounded = false),
                role = Role.Tab,
                onClick = onClick,
            )
            .testTag("nav-${tab.name.lowercase()}")
            .semantics {
                if (!labelled) contentDescription = tab.title
                else if (tab == MobileTab.MORE)
                    contentDescription = if (moreOpen) "Close More" else "Open More"
            },
        contentAlignment = Alignment.Center,
    ) {
        val label: @Composable () -> Unit = {
            Text(
                tab.title,
                style =
                    type.caption2.copy(
                        fontSize = if (island) 13.sp else 11.sp,
                        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
                        letterSpacing = 0.sp,
                    ),
                color = tint,
                maxLines = 1,
                softWrap = false,
            )
        }
        val icon: @Composable () -> Unit = {
            Box(
                Modifier.graphicsLayer {
                    scaleX = magnify
                    scaleY = magnify
                }
            ) {
                TabIcon(tab, badge, moreOpen, tint)
            }
        }
        when {
            island && !vertical ->
                Row(
                    Modifier.padding(horizontal = 14.dp).animateContentSize(spring(.8f, 500f)),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    icon()
                    AnimatedVisibility(
                        selected,
                        enter = expandHorizontally(spring(.8f, 500f)) + fadeIn(tween(200, 60)),
                        exit = shrinkHorizontally(spring(.8f, 500f)) + fadeOut(tween(90)),
                    ) {
                        Row {
                            Spacer(Modifier.width(8.dp))
                            label()
                        }
                    }
                }
            metrics.labels ->
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    icon()
                    Spacer(Modifier.height(2.dp))
                    label()
                }
            else -> icon()
        }
    }
}

/** The tab's glyph with its badge; More shows a chevron while its sheet is open. */
@Composable
internal fun TabIcon(tab: MobileTab, badge: String, moreOpen: Boolean, tint: Color) {
    BadgedBox(badge = { if (badge.isNotEmpty() && !moreOpen) Badge { Text(badge) } }) {
        Crossfade(tab == MobileTab.MORE && moreOpen, label = "more") { open ->
            Icon(if (open) Glyph.CHEVRON_DOWN else tab.glyph, null, tint = tint, size = 24.dp)
        }
    }
}

/** The screen's creation command as a tinted glass drop beside the bar. */
@Composable
private fun PrimaryOrb(action: ChromeAction, size: Dp, backdrop: GlassBackdrop?) {
    val interaction = remember {
        androidx.compose.foundation.interaction.MutableInteractionSource()
    }
    val pressed by interaction.collectIsPressedAsState()
    val scale by
        animateFloatAsState(if (pressed) .9f else 1f, spring(.5f, 600f), label = "orb-press")
    Box(
        Modifier.size(size)
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            .glass(backdrop, CircleShape, GlassStyles.tinted(palette.accent))
            .clip(CircleShape)
            .clickable(
                interactionSource = interaction,
                indication = androidx.compose.material3.ripple(color = palette.onAccent),
                role = Role.Button,
                onClick = action.onClick,
            )
            .semantics { contentDescription = action.title }
            .testTag("chrome-${action.id}"),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            action.glyph ?: Glyph.ADD,
            null,
            tint = palette.onAccent,
            size = 24.dp,
            weight = GlyphWeight.MEDIUM,
        )
    }
}

/** Each tab's badge: Inbox attention, unread mail, and unread channel messages on More. */
@Composable
internal fun rememberTabBadges(store: MobileStore): (MobileTab) -> String {
    val activity by store.workspace.activity.collectAsState()
    val channels by store.channels.slice.collectAsState()
    val mail by store.mail.slice.collectAsState()
    val attention = activity.summary?.attention ?: 0
    return { tab ->
        when (tab) {
            MobileTab.INBOX -> if (attention > 0) attention.toString() else ""
            MobileTab.MAIL -> mail.unread_label
            MobileTab.MORE -> channels.unread_label
            else -> ""
        }
    }
}
