package com.getdieter.mobile.design

import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.runtime.*
import com.getdieter.core.presentation.Markdown

/**
 * Transcript and document Markdown: the core's profile parser (with its link detection) drawn by
 * [MarkdownDocument], selectable, every link through [openUrl].
 */
@Composable
internal fun RichText(value: String, openUrl: (String) -> Unit = {}) {
    val blocks = remember(value) { Markdown.parse(value) }
    SelectionContainer { MarkdownDocument(blocks, openUrl) }
}
