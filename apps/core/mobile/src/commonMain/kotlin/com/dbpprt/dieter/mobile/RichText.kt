package com.dbpprt.dieter.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.*
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.core.presentation.DetectedLinks
import com.dbpprt.dieter.core.presentation.Markdown
import com.dbpprt.dieter.core.presentation.MarkdownBlock

/** Uses the same block parser and link detection as every shipping client. */
@Composable
internal fun RichText(value: String, openUrl: (String) -> Unit = {}) {
    val blocks = remember(value) { Markdown.parse(value) }
    val text = LocalContentColor.current.takeIf { it != Color.Unspecified } ?: palette.label
    SelectionContainer {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            blocks.forEach { block ->
                when (block) {
                    is MarkdownBlock.Code ->
                        Column(
                            Modifier.fillMaxWidth()
                                .clip(RoundedCornerShape(12.dp))
                                .background(palette.inset)
                                .border(
                                    .5.dp,
                                    palette.separator.copy(alpha = .4f),
                                    RoundedCornerShape(12.dp),
                                )
                        ) {
                            if (block.language.isNotEmpty())
                                Text(
                                    block.language,
                                    Modifier.padding(start = 12.dp, top = 8.dp),
                                    style = type.caption.copy(fontWeight = FontWeight.Medium),
                                    color = palette.secondaryLabel,
                                )
                            Text(
                                block.text,
                                Modifier.horizontalScroll(rememberScrollState()).padding(12.dp),
                                style = type.mono,
                                color = palette.label,
                            )
                        }
                    is MarkdownBlock.Table ->
                        Column(
                            Modifier.clip(RoundedCornerShape(12.dp))
                                .border(.5.dp, palette.separator, RoundedCornerShape(12.dp))
                                .horizontalScroll(rememberScrollState())
                        ) {
                            (listOf(block.header) + block.rows).forEachIndexed { index, cells ->
                                Row(
                                    Modifier.background(
                                        if (index == 0) palette.fill else Color.Transparent
                                    )
                                ) {
                                    cells.forEach { cell ->
                                        Text(
                                            inlineMarkdown(cell, openUrl),
                                            Modifier.widthIn(min = 96.dp, max = 220.dp)
                                                .padding(horizontal = 10.dp, vertical = 7.dp),
                                            style =
                                                type.subheadline.copy(
                                                    fontWeight =
                                                        if (index == 0) FontWeight.SemiBold
                                                        else FontWeight.Normal
                                                ),
                                            color = text,
                                        )
                                    }
                                }
                                if (index < block.rows.size) Hairline()
                            }
                        }
                    is MarkdownBlock.Heading ->
                        Text(
                            inlineMarkdown(block.text, openUrl),
                            Modifier.padding(top = 4.dp),
                            style = type.title3,
                            color = text,
                        )
                    is MarkdownBlock.Bullet ->
                        Row {
                            Text(
                                "•",
                                Modifier.width(18.dp).padding(start = 4.dp),
                                style = type.body,
                                color = palette.secondaryLabel,
                            )
                            Text(
                                inlineMarkdown(block.text, openUrl),
                                style = type.body,
                                color = text,
                            )
                        }
                    is MarkdownBlock.Paragraph ->
                        Text(inlineMarkdown(block.text, openUrl), style = type.body, color = text)
                }
            }
        }
    }
}

private val inlinePattern = Regex("(\\*\\*([^*]+)\\*\\*|`([^`]+)`|\\[([^]]+)]\\(([^)]+)\\))")

@Composable
private fun inlineMarkdown(value: String, openUrl: (String) -> Unit): AnnotatedString {
    val link =
        if (palette.accent == Color.Black || palette.accent == Color.White) palette.info
        else palette.accent
    val linkStyle = SpanStyle(color = link, textDecoration = TextDecoration.None)
    val codeStyle = SpanStyle(background = palette.fill, fontFamily = FontFamily.Monospace)
    return remember(value, linkStyle, codeStyle, openUrl) {
        buildAnnotatedString {
            fun link(label: String, url: String) {
                withLink(
                    LinkAnnotation.Clickable(url, TextLinkStyles(linkStyle)) { openUrl(url) }
                ) {
                    append(label)
                }
            }
            fun plain(text: String) {
                var cursor = 0
                DetectedLinks.find(text).forEach { match ->
                    append(text.substring(cursor, match.range.first))
                    link(text.substring(match.range), match.url)
                    cursor = match.range.last + 1
                }
                append(text.substring(cursor))
            }
            var cursor = 0
            inlinePattern.findAll(value).forEach { match ->
                plain(value.substring(cursor, match.range.first))
                when {
                    match.groupValues[2].isNotEmpty() ->
                        withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) {
                            append(match.groupValues[2])
                        }
                    match.groupValues[3].isNotEmpty() ->
                        withStyle(codeStyle) { append(" ${match.groupValues[3]} ") }
                    else -> link(match.groupValues[4], match.groupValues[5])
                }
                cursor = match.range.last + 1
            }
            plain(value.substring(cursor))
        }
    }
}
