package com.getdieter.mobile.design

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.getdieter.mobile.app.ChromeAction

// The one list style every list page shares (Inbox, Chats, Projects, Mail, Channels, …): slim
// section headers with a hairline, and full-width rows of an avatar or icon tile, a title line with
// trailing meta, and an optional second line with a trailing badge. Grouped cards stay for forms.

/** Width of a two-line row's leading slot. */
internal val ListLeading = 52.dp

/** A row avatar or icon tile's size inside a two-line row's leading slot. */
internal val ListTile = 46.dp

/** A single-line row's leading slot; its tile shrinks to fit, so the row stays 56 dp. */
private val ListLeadingCompact = 40.dp

/**
 * A list section's header: [title] and [count] in [tint], then a hairline to the edge, and an
 * optional [trailing] control (a collapse chevron, an action).
 */
@Composable
internal fun ListSectionHeader(
    title: String,
    modifier: Modifier = Modifier,
    count: Int? = null,
    tint: Color = palette.secondaryLabel,
    trailing: (@Composable () -> Unit)? = null,
) {
    val hairline = with(LocalDensity.current) { 1f / density }.dp
    Row(
        modifier
            .fillMaxWidth()
            .heightIn(min = 34.dp)
            .padding(start = 16.dp, end = if (trailing != null) 6.dp else 16.dp, top = 10.dp)
            .semantics(mergeDescendants = true) { heading() },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        // Not weighted: the hairline takes the rest of the row, so a trailing control sits at the
        // edge.
        Text(
            title,
            Modifier.widthIn(max = 280.dp),
            style = type.footnote.copy(fontWeight = FontWeight.SemiBold),
            color = tint,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        if (count != null)
            Text(
                "$count",
                style = type.footnote.copy(fontWeight = FontWeight.Medium),
                color = tint.copy(alpha = .8f),
            )
        Box(
            Modifier.weight(1f).padding(start = 4.dp).height(hairline).background(palette.separator)
        )
        trailing?.invoke()
    }
}

/** A row's background: selected, a faint tint (pinned and similar), or the screen. */
@Composable
internal fun listRowSurface(selected: Boolean = false, tinted: Boolean = false): Color =
    when {
        selected -> palette.accentContainer
        tinted -> lerp(palette.background, palette.label, if (palette.dark) .07f else .035f)
        else -> palette.background
    }

/**
 * The list row: [leading] (an avatar or [ListIconTile]), a first line of [title] and trailing
 * [meta], and an optional second line of [subtitle] and trailing [badge]. Rows are full width, at
 * least 72 dp with a second line and 56 dp without (the leading tile then shrinks to 40 dp), and
 * grow with the font scale. On iOS a hairline separates a row from the one above unless it is
 * [first] in its section. A row with neither [onClick] nor [onLongClick] only informs.
 */
@Composable
internal fun ListRow(
    onClick: (() -> Unit)?,
    modifier: Modifier = Modifier,
    onLongClick: (() -> Unit)? = null,
    surface: Color = palette.background,
    first: Boolean = false,
    leading: (@Composable () -> Unit)? = null,
    meta: @Composable RowScope.() -> Unit = {},
    subtitle: (@Composable RowScope.() -> Unit)? = null,
    badge: @Composable RowScope.() -> Unit = {},
    title: @Composable RowScope.() -> Unit,
) {
    val separator = palette.separator
    val hairline = with(LocalDensity.current) { 1f / density }.dp
    val iOS = apple
    val slot = if (subtitle != null) ListLeading else ListLeadingCompact
    val inset = if (leading != null) 12.dp + slot + 12.dp else 16.dp
    Row(
        modifier
            .fillMaxWidth()
            .heightIn(min = if (subtitle != null) 72.dp else 56.dp)
            .background(surface)
            .then(
                if (onClick != null || onLongClick != null)
                    Modifier.pressable(
                        onClick = onClick ?: {},
                        onLongClick = onLongClick,
                        highlight = true,
                    )
                else Modifier
            )
            .drawBehind {
                if (iOS && !first)
                    drawRect(
                        separator,
                        topLeft = Offset(inset.toPx(), 0f),
                        size = Size(size.width - inset.toPx(), hairline.toPx()),
                    )
            }
            .padding(start = if (leading != null) 12.dp else 16.dp, end = 16.dp)
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (leading != null)
            Box(Modifier.size(slot), contentAlignment = Alignment.Center) { leading() }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                title()
                meta()
            }
            if (subtitle != null)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    subtitle()
                    badge()
                }
        }
        if (subtitle == null) badge()
    }
}

/** A row's title: one line, semibold, filling the line before its meta. */
@Composable
internal fun RowScope.ListTitle(
    text: String,
    modifier: Modifier = Modifier,
    color: Color = palette.label,
) {
    Text(
        text,
        modifier.weight(1f),
        style = type.bodyEmphasized.copy(fontWeight = FontWeight.SemiBold),
        color = color,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

/** A row's trailing meta on its first line: a time, a count, a state. */
@Composable
internal fun ListMeta(
    text: String,
    modifier: Modifier = Modifier,
    color: Color = palette.secondaryLabel,
) {
    if (text.isEmpty()) return
    Text(
        text,
        modifier.padding(start = 6.dp),
        style = type.footnote,
        color = color,
        maxLines = 1,
    )
}

/** A row's second line: one line filling the space before its badge. */
@Composable
internal fun RowScope.ListSubtitle(
    text: AnnotatedString,
    modifier: Modifier = Modifier,
    color: Color = palette.secondaryLabel,
) {
    Text(
        text,
        modifier.weight(1f),
        style = type.subheadline,
        color = color,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

@Composable
internal fun RowScope.ListSubtitle(
    text: String,
    modifier: Modifier = Modifier,
    color: Color = palette.secondaryLabel,
) = ListSubtitle(AnnotatedString(text), modifier, color)

/** A leading icon tile for rows without a project avatar: [glyph] on a soft [tint]. */
@Composable
internal fun ListIconTile(
    glyph: Glyph,
    tint: Color = palette.secondaryLabel,
    size: Dp = ListTile,
    contentDescription: String? = null,
) {
    Box(
        Modifier.size(size)
            .clip(RoundedCornerShape(size * .28f))
            .background(
                if (tint == palette.secondaryLabel) palette.fill
                else tint.copy(alpha = if (palette.dark) .22f else .14f)
            ),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            glyph,
            contentDescription,
            tint =
                if (tint == palette.secondaryLabel) tint else tint.readableOn(palette.background),
            size = size * .48f,
        )
    }
}

/**
 * A list page's search: a top bar toggle ([action]) that shows a field above the list ([Field]), so
 * no page spends permanent height on search. A non-empty query keeps the field shown.
 */
internal class ListSearch(
    private val id: String,
    private val placeholder: String,
    private val queryState: androidx.compose.runtime.MutableState<String>,
    private val openState: androidx.compose.runtime.MutableState<Boolean>,
) {
    var query: String
        get() = queryState.value
        set(value) {
            queryState.value = value
        }

    /** Whether the field is on screen. */
    val shown: Boolean
        get() = openState.value || queryState.value.isNotEmpty()

    /** The top bar's search toggle; closing it clears the query. */
    fun action(): ChromeAction =
        ChromeAction("$id-search", "Search", Glyph.SEARCH, checked = shown) {
            if (shown) {
                queryState.value = ""
                openState.value = false
            } else openState.value = true
        }

    @Composable
    fun Field(modifier: Modifier = Modifier) {
        SearchField(
            query,
            { query = it },
            placeholder,
            modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
            testTag = "$id-search-field",
        )
    }
}

/** A [ListSearch] whose query and open state survive configuration changes. */
@Composable
internal fun rememberListSearch(id: String, placeholder: String): ListSearch {
    val query = rememberSaveable(id) { mutableStateOf("") }
    val open = rememberSaveable(id) { mutableStateOf(false) }
    return ListSearch(id, placeholder, query, open)
}

/** A row's badge spacing on its second line. */
internal val ListBadgeGap = Modifier.padding(start = 8.dp)
