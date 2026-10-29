package com.getdieter.mobile.design

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.*
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.getdieter.core.files.SyntaxKind
import com.getdieter.core.files.syntaxRanges
import com.getdieter.core.presentation.Markdown
import com.getdieter.core.presentation.MarkdownBlock
import com.getdieter.core.presentation.MarkdownDiagrams
import com.getdieter.core.presentation.MarkdownInline
import com.getdieter.core.presentation.MarkdownListItem
import com.getdieter.core.presentation.TableAlignment
import com.getdieter.mobile.platform.MarkdownDiagram

/*
 * The renderer of the Markdown profile (docs/proposals/agent-mail.md §3.7) over the core's block
 * and inline tree: six heading sizes, nested and task lists, quotes, rules, highlighted code and
 * GFM tables that scroll sideways on their own. Nothing is fetched: an image is its alt text and a
 * link. Mail bodies render as lazy list items; transcripts and documents use [MarkdownDocument].
 */

/** Tables list this many rows until the reader asks for all of them; widths come from them. */
private const val TABLE_ROWS = 200

/** Where links go. [linkable] decides which links render as links at all. */
@Stable
internal class MarkdownLinks(open: (String) -> Unit, linkable: (String) -> Boolean) {
    var open by mutableStateOf(open)
    var linkable by mutableStateOf(linkable)
}

@Composable
private fun rememberMarkdownLinks(
    open: (String) -> Unit,
    linkable: (String) -> Boolean,
): MarkdownLinks {
    val links = remember { MarkdownLinks(open, linkable) }
    SideEffect {
        links.open = open
        links.linkable = linkable
    }
    return links
}

/** The colors and text styles one document renders with. */
@Immutable
private data class MarkdownStyle(
    val text: Color,
    val secondary: Color,
    val link: Color,
    val fill: Color,
    val inset: Color,
    val cell: Color,
    val separator: Color,
    val dark: Boolean,
    val type: DieterType,
    /** Changes whenever [MarkdownLinks.linkable] may answer differently. */
    val linkKey: Any?,
    val diagrams: Boolean,
) {
    val body: TextStyle
        get() = type.body.copy(color = text)

    fun heading(level: Int): TextStyle =
        when (level) {
            1 -> type.title1
            2 -> type.title2
            3 -> type.title3
            4 -> type.headline
            5 -> type.subheadline.copy(fontWeight = FontWeight.SemiBold)
            else -> type.footnote.copy(fontWeight = FontWeight.SemiBold)
        }.copy(color = if (level >= 6) secondary else text)
}

@Composable
private fun rememberMarkdownStyle(linkKey: Any?, diagrams: Boolean = false): MarkdownStyle {
    val content = LocalContentColor.current
    val text = if (content == Color.Unspecified) palette.label else content
    val link =
        if (palette.accent == Color.Black || palette.accent == Color.White) palette.info
        else palette.accent
    val colors = palette
    val styles = type
    return remember(text, link, colors, styles, linkKey, diagrams) {
        MarkdownStyle(
            text = text,
            secondary = colors.secondaryLabel,
            link = link,
            fill = colors.fill,
            inset = colors.inset,
            cell = colors.cell,
            separator = colors.separator,
            dark = colors.dark,
            type = styles,
            linkKey = linkKey,
            diagrams = diagrams,
        )
    }
}

/**
 * [blocks] as lazy items, one per top-level block, so a long body composes only what shows.
 * [linkKey] must change when [linkable] starts answering differently, e.g. once a workspace path is
 * known.
 */
internal fun LazyListScope.markdownDocument(
    blocks: List<MarkdownBlock>,
    linkHandler: (String) -> Unit,
    linkable: (String) -> Boolean = { true },
    linkKey: Any? = null,
    key: String = "markdown",
    horizontalPadding: Dp = ScreenMargin + 4.dp,
    diagrams: Boolean = false,
) {
    itemsIndexed(
        blocks,
        key = { index, _ -> "$key-$index" },
        contentType = { _, block -> contentType(block) },
    ) { index, block ->
        val links = rememberMarkdownLinks(linkHandler, linkable)
        val style = rememberMarkdownStyle(linkKey, diagrams)
        Box(
            Modifier.fillMaxWidth()
                .padding(horizontal = horizontalPadding)
                .padding(top = if (index == 0) 0.dp else spacingBefore(block))
        ) {
            SelectionContainer { BlockView(block, style, links, depth = 0) }
        }
    }
}

/** [blocks] in a column, for content that is not a lazy list itself. */
@Composable
internal fun MarkdownDocument(
    blocks: List<MarkdownBlock>,
    linkHandler: (String) -> Unit,
    modifier: Modifier = Modifier,
    linkable: (String) -> Boolean = { true },
    linkKey: Any? = null,
) {
    val links = rememberMarkdownLinks(linkHandler, linkable)
    val style = rememberMarkdownStyle(linkKey)
    Column(modifier) { Blocks(blocks, style, links, depth = 0) }
}

private fun contentType(block: MarkdownBlock): String =
    when (block) {
        is MarkdownBlock.Paragraph -> "paragraph"
        is MarkdownBlock.Heading -> "heading"
        is MarkdownBlock.Code -> "code"
        is MarkdownBlock.Quote -> "quote"
        is MarkdownBlock.ListBlock -> "list"
        MarkdownBlock.Rule -> "rule"
        is MarkdownBlock.Table -> "table"
    }

private fun spacingBefore(block: MarkdownBlock): Dp =
    when (block) {
        is MarkdownBlock.Heading -> if (block.level <= 2) 20.dp else 14.dp
        else -> 10.dp
    }

@Composable
private fun Blocks(
    blocks: List<MarkdownBlock>,
    style: MarkdownStyle,
    links: MarkdownLinks,
    depth: Int,
    compact: Boolean = false,
) {
    blocks.forEachIndexed { index, block ->
        if (index > 0) Spacer(Modifier.height(if (compact) 4.dp else spacingBefore(block)))
        BlockView(block, style, links, depth)
    }
}

@Composable
private fun BlockView(
    block: MarkdownBlock,
    style: MarkdownStyle,
    links: MarkdownLinks,
    depth: Int,
) {
    when (block) {
        is MarkdownBlock.Paragraph ->
            Text(rememberInlines(block.inlines, style, links), style = style.body)
        is MarkdownBlock.Heading ->
            Text(
                rememberInlines(block.inlines, style, links),
                Modifier.semantics { heading() },
                style = style.heading(block.level),
            )
        is MarkdownBlock.Code -> {
            val kind = if (style.diagrams) MarkdownDiagrams.kind(block.language) else null
            if (kind == null) CodeView(block, style)
            else
                MarkdownDiagram(kind, block.text, style.dark, block.language) {
                    CodeView(block, style)
                }
        }
        is MarkdownBlock.Quote -> QuoteView(block, style, links, depth)
        is MarkdownBlock.ListBlock -> ListView(block, style, links, depth)
        MarkdownBlock.Rule -> Hairline(Modifier.padding(vertical = 6.dp))
        is MarkdownBlock.Table -> TableView(block, style, links)
    }
}

// Inline text ---------------------------------------------------------------------------------

@Composable
private fun rememberInlines(
    inlines: List<MarkdownInline>,
    style: MarkdownStyle,
    links: MarkdownLinks,
): AnnotatedString =
    remember(inlines, style, links) {
        buildAnnotatedString { appendInlines(inlines, style, links) }
    }

private fun AnnotatedString.Builder.appendInlines(
    inlines: List<MarkdownInline>,
    style: MarkdownStyle,
    links: MarkdownLinks,
) {
    for (inline in inlines) {
        when (inline) {
            is MarkdownInline.Text -> append(inline.text)
            is MarkdownInline.Code ->
                withStyle(
                    SpanStyle(
                        fontFamily = style.type.mono.fontFamily,
                        background = style.fill,
                    )
                ) {
                    append(inline.text)
                }
            is MarkdownInline.Emphasis ->
                withStyle(SpanStyle(fontStyle = FontStyle.Italic)) {
                    appendInlines(inline.children, style, links)
                }
            is MarkdownInline.Strong ->
                withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) {
                    appendInlines(inline.children, style, links)
                }
            is MarkdownInline.Strikethrough ->
                withStyle(SpanStyle(textDecoration = TextDecoration.LineThrough)) {
                    appendInlines(inline.children, style, links)
                }
            is MarkdownInline.Link ->
                link(inline.url, style, links) { appendInlines(inline.children, style, links) }
            // Never loaded: the alt text (or the address) links to the image.
            is MarkdownInline.Image ->
                link(inline.url, style, links) { append(inline.alt.ifBlank { inline.url }) }
            is MarkdownInline.Break -> append('\n')
        }
    }
}

private fun AnnotatedString.Builder.link(
    url: String,
    style: MarkdownStyle,
    links: MarkdownLinks,
    content: AnnotatedString.Builder.() -> Unit,
) {
    if (!links.linkable(url)) {
        content()
        return
    }
    withLink(
        LinkAnnotation.Clickable(
            url,
            TextLinkStyles(SpanStyle(color = style.link, textDecoration = TextDecoration.None)),
        ) {
            links.open(url)
        }
    ) {
        content()
    }
}

// Code --------------------------------------------------------------------------------------

@Composable
private fun CodeView(block: MarkdownBlock.Code, style: MarkdownStyle) {
    val highlighted =
        remember(block, style) {
            val language = Markdown.codeLanguage(block.language)
            buildAnnotatedString {
                append(block.text)
                for (range in syntaxRanges(block.text, language)) {
                    val end = minOf(range.end, block.text.length)
                    if (range.start < end)
                        addStyle(syntaxStyle(range.kind, style.dark), range.start, end)
                }
            }
        }
    val shape = RoundedCornerShape(12.dp)
    Column(
        Modifier.fillMaxWidth()
            .clip(shape)
            .background(style.inset)
            .border(.5.dp, style.separator.copy(alpha = .4f), shape)
    ) {
        if (block.language.isNotEmpty())
            Text(
                block.language,
                Modifier.padding(start = 12.dp, top = 8.dp, end = 12.dp),
                style = style.type.caption.copy(fontWeight = FontWeight.Medium),
                color = style.secondary,
            )
        Text(
            highlighted,
            Modifier.horizontalScroll(rememberScrollState()).padding(12.dp),
            style = style.type.mono.copy(color = style.text),
            softWrap = false,
        )
    }
}

/** Xcode's default themes, so code reads the same in every Dieter client. */
private fun syntaxStyle(kind: SyntaxKind, dark: Boolean): SpanStyle {
    fun color(light: Long, night: Long) = Color(if (dark) night else light)
    return when (kind) {
        SyntaxKind.COMMENT -> SpanStyle(color = color(0xFF5D6C79, 0xFF7F8C98))
        SyntaxKind.STRING -> SpanStyle(color = color(0xFFC41A16, 0xFFFC6A5D))
        SyntaxKind.NUMBER,
        SyntaxKind.CONSTANT -> SpanStyle(color = color(0xFF1C00CF, 0xFFD0BF69))
        SyntaxKind.KEYWORD,
        SyntaxKind.TAG -> SpanStyle(color = color(0xFF9B2393, 0xFFFC5FA3))
        SyntaxKind.TYPE,
        SyntaxKind.LINK -> SpanStyle(color = color(0xFF0B4F79, 0xFF5DD8FF))
        SyntaxKind.FUNCTION -> SpanStyle(color = color(0xFF326D74, 0xFF67B7A4))
        SyntaxKind.ANNOTATION,
        SyntaxKind.ATTRIBUTE -> SpanStyle(color = color(0xFF815F03, 0xFFBF8555))
        SyntaxKind.PROPERTY,
        SyntaxKind.VARIABLE -> SpanStyle(color = color(0xFF3E6D8F, 0xFF41A1C0))
        SyntaxKind.HEADING ->
            SpanStyle(color = color(0xFF9B2393, 0xFFFC5FA3), fontWeight = FontWeight.Bold)
        SyntaxKind.EMPHASIS -> SpanStyle(fontStyle = FontStyle.Italic)
    }
}

// Quotes and lists ----------------------------------------------------------------------------

@Composable
private fun QuoteView(
    block: MarkdownBlock.Quote,
    style: MarkdownStyle,
    links: MarkdownLinks,
    depth: Int,
) {
    val bar = style.separator
    Column(
        Modifier.fillMaxWidth()
            .drawBehind {
                drawRoundRect(
                    bar,
                    size = Size(3.dp.toPx(), size.height),
                    cornerRadius = CornerRadius(1.5.dp.toPx()),
                )
            }
            .padding(start = 14.dp)
    ) {
        Blocks(block.blocks, style.copy(text = style.secondary), links, depth + 1)
    }
}

@Composable
private fun ListView(
    block: MarkdownBlock.ListBlock,
    style: MarkdownStyle,
    links: MarkdownLinks,
    depth: Int,
) {
    val digits = (block.start + block.items.size - 1).coerceAtLeast(1).toString().length
    val markerWidth = if (block.ordered) (10 * digits + 12).dp else 20.dp
    val line = with(LocalDensity.current) { style.body.lineHeight.toDp() }
    Column(Modifier.fillMaxWidth()) {
        block.items.forEachIndexed { index, item ->
            if (index > 0) Spacer(Modifier.height(4.dp))
            Row(Modifier.fillMaxWidth()) {
                Box(
                    Modifier.width(markerWidth).heightIn(min = line),
                    contentAlignment = Alignment.TopStart,
                ) {
                    Marker(block, item, index, depth, style, line)
                }
                Column(Modifier.weight(1f)) {
                    Blocks(item.blocks, style, links, depth + 1, compact = true)
                }
            }
        }
    }
}

@Composable
private fun Marker(
    block: MarkdownBlock.ListBlock,
    item: MarkdownListItem,
    index: Int,
    depth: Int,
    style: MarkdownStyle,
    line: Dp,
) {
    val checked = item.checked
    when {
        checked != null ->
            Box(Modifier.height(line), contentAlignment = Alignment.Center) {
                Checkbox(checked, style)
            }
        block.ordered ->
            Text(
                "${block.start + index}.",
                style = style.body.copy(color = style.secondary),
                maxLines = 1,
            )
        else ->
            Text(
                when (depth % 3) {
                    0 -> "•"
                    1 -> "◦"
                    else -> "▪"
                },
                Modifier.padding(start = 4.dp),
                style = style.body.copy(color = style.secondary),
            )
    }
}

/** A read-only task box. */
@Composable
private fun Checkbox(checked: Boolean, style: MarkdownStyle) {
    val shape = RoundedCornerShape(4.dp)
    Box(
        Modifier.size(16.dp)
            .clip(shape)
            .then(
                if (checked) Modifier.background(style.link)
                else Modifier.border(1.5.dp, style.secondary, shape)
            )
            .semantics { contentDescription = if (checked) "Done" else "Not done" },
        contentAlignment = Alignment.Center,
    ) {
        if (checked)
            Icon(
                Glyph.CHECK,
                null,
                tint = if (style.dark) Color.Black else Color.White,
                size = 12.dp,
                weight = GlyphWeight.BOLD,
            )
    }
}

// Tables ------------------------------------------------------------------------------------

@Composable
private fun TableView(block: MarkdownBlock.Table, style: MarkdownStyle, links: MarkdownLinks) {
    var all by remember(block) { mutableStateOf(false) }
    val rows = if (all || block.rows.size <= TABLE_ROWS) block.rows else block.rows.take(TABLE_ROWS)
    val header =
        remember(block, style, links) {
            block.header.map { cell ->
                buildAnnotatedString { appendInlines(Markdown.inline(cell), style, links) }
            }
        }
    val body =
        remember(rows, style, links) {
            rows.map { row ->
                row.map { cell ->
                    buildAnnotatedString { appendInlines(Markdown.inline(cell), style, links) }
                }
            }
        }
    val scroll = rememberScrollState()
    val shape = RoundedCornerShape(12.dp)
    Column(Modifier.fillMaxWidth()) {
        Box(
            Modifier.fillMaxWidth()
                .clip(shape)
                .background(style.cell)
                .border(.5.dp, style.separator, shape)
                .testTag("markdown-table")
        ) {
            TableLayout(
                header,
                body,
                block.alignments,
                style,
                Modifier.horizontalScroll(scroll),
            )
            Box(Modifier.matchParentSize()) {
                if (scroll.canScrollBackward)
                    Box(
                        Modifier.align(Alignment.CenterStart)
                            .fillMaxHeight()
                            .width(24.dp)
                            .background(
                                Brush.horizontalGradient(listOf(style.cell, style.cell.copy(0f)))
                            )
                    )
                if (scroll.canScrollForward)
                    Box(
                        Modifier.align(Alignment.CenterEnd)
                            .fillMaxHeight()
                            .width(32.dp)
                            .background(
                                Brush.horizontalGradient(listOf(style.cell.copy(0f), style.cell))
                            )
                    )
            }
        }
        if (!all && block.rows.size > TABLE_ROWS)
            Text(
                "Show all ${block.rows.size} rows",
                Modifier.padding(top = 8.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .pressable(onClick = { all = true })
                    .padding(horizontal = 8.dp, vertical = 6.dp)
                    .testTag("markdown-table-all"),
                style = style.type.subheadline.copy(fontWeight = FontWeight.Medium),
                color = style.link,
            )
    }
}

/**
 * Columns as wide as their widest cell in the header and the first [TABLE_ROWS] rows, within 64–320
 * dp; cells wrap inside their column and follow its alignment. The header sits on the fill color
 * and hairlines separate the rows.
 */
@Composable
private fun TableLayout(
    header: List<AnnotatedString>,
    rows: List<List<AnnotatedString>>,
    alignments: List<TableAlignment>,
    style: MarkdownStyle,
    modifier: Modifier,
) {
    val columns = header.size
    val headerStyle =
        style.type.subheadline.copy(color = style.text, fontWeight = FontWeight.SemiBold)
    val cellStyle = style.type.subheadline.copy(color = style.text)
    val empty = remember { AnnotatedString("") }
    Layout(
        contents =
            listOf(
                { Box(Modifier.background(style.fill)) },
                {
                    for (row in -1 until rows.size) {
                        val cells = if (row < 0) header else rows[row]
                        for (column in 0 until columns) {
                            val align =
                                when (alignments.getOrNull(column)) {
                                    TableAlignment.CENTER -> TextAlign.Center
                                    TableAlignment.END -> TextAlign.End
                                    else -> TextAlign.Start
                                }
                            Text(
                                cells.getOrNull(column) ?: empty,
                                Modifier.padding(horizontal = 10.dp, vertical = 7.dp),
                                style =
                                    (if (row < 0) headerStyle else cellStyle).copy(
                                        textAlign = align
                                    ),
                            )
                        }
                    }
                },
                { repeat(rows.size) { Box(Modifier.background(style.separator)) } },
            ),
        modifier = modifier,
    ) { (backgrounds, cells, rules), _ ->
        val narrowest = 64.dp.roundToPx()
        val widest = 320.dp.roundToPx()
        val count = rows.size + 1
        val sized = minOf(count, TABLE_ROWS + 1)
        val widths =
            IntArray(columns) { column ->
                var width = 0
                for (row in 0 until sized) width =
                    maxOf(
                        width,
                        cells[row * columns + column].maxIntrinsicWidth(Constraints.Infinity),
                    )
                width.coerceIn(narrowest, widest)
            }
        val placeables = cells.mapIndexed { index, cell ->
            cell.measure(Constraints.fixedWidth(widths[index % columns]))
        }
        val heights =
            IntArray(count) { row ->
                var height = 0
                for (column in 0 until columns) height =
                    maxOf(height, placeables[row * columns + column].height)
                height
            }
        val hairline = 1
        val width = widths.sum()
        val height = heights.sum() + (count - 1) * hairline
        val background = backgrounds.single().measure(Constraints.fixed(width, heights[0]))
        val separators = rules.map { it.measure(Constraints.fixed(width, hairline)) }
        layout(width, height) {
            background.place(0, 0)
            var y = 0
            for (row in 0 until count) {
                var x = 0
                for (column in 0 until columns) {
                    placeables[row * columns + column].place(x, y)
                    x += widths[column]
                }
                y += heights[row]
                if (row < count - 1) {
                    separators[row].place(0, y)
                    y += hairline
                }
            }
        }
    }
}
