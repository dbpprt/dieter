package com.dbpprt.dieter.mobile

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
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
    SelectionContainer {
        Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
            blocks.forEach { block ->
                when (block) {
                    is MarkdownBlock.Code ->
                        Surface(
                            shape = RoundedCornerShape(9.dp),
                            color = colors.surfaceContainerHigh,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Column(Modifier.padding(11.dp)) {
                                if (block.language.isNotEmpty())
                                    Text(
                                        block.language,
                                        style = MaterialTheme.typography.labelSmall,
                                        color = colors.onSurfaceVariant,
                                    )
                                Text(
                                    block.text,
                                    modifier = Modifier.horizontalScroll(rememberScrollState()),
                                    style = MaterialTheme.typography.bodySmall,
                                    fontFamily = FontFamily.Monospace,
                                )
                            }
                        }
                    is MarkdownBlock.Table ->
                        Column(Modifier.horizontalScroll(rememberScrollState())) {
                            (listOf(block.header) + block.rows).forEachIndexed { index, cells ->
                                Row {
                                    cells.forEach { cell ->
                                        Text(
                                            inlineMarkdown(cell, openUrl),
                                            Modifier.widthIn(min = 100.dp, max = 220.dp)
                                                .padding(horizontal = 8.dp, vertical = 6.dp),
                                            fontWeight =
                                                if (index == 0) FontWeight.SemiBold
                                                else FontWeight.Normal,
                                            style = MaterialTheme.typography.bodySmall,
                                        )
                                    }
                                }
                                HorizontalDivider(color = colors.outlineVariant)
                            }
                        }
                    is MarkdownBlock.Heading ->
                        Text(
                            inlineMarkdown(block.text, openUrl),
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold,
                        )
                    is MarkdownBlock.Bullet ->
                        Text(
                            inlineMarkdown("• " + block.text, openUrl),
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    is MarkdownBlock.Paragraph ->
                        Text(
                            inlineMarkdown(block.text, openUrl),
                            style = MaterialTheme.typography.bodyMedium,
                        )
                }
            }
        }
    }
}

private val inlinePattern = Regex("(\\*\\*([^*]+)\\*\\*|`([^`]+)`|\\[([^]]+)]\\(([^)]+)\\))")

@Composable
private fun inlineMarkdown(value: String, openUrl: (String) -> Unit): AnnotatedString {
    val linkStyle = SpanStyle(color = colors.primary, textDecoration = TextDecoration.Underline)
    val codeStyle =
        SpanStyle(
            color = colors.primary,
            background = colors.surfaceContainerHigh,
            fontFamily = FontFamily.Monospace,
        )
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
                        withStyle(codeStyle) { append(match.groupValues[3]) }
                    else -> link(match.groupValues[4], match.groupValues[5])
                }
                cursor = match.range.last + 1
            }
            plain(value.substring(cursor))
        }
    }
}
