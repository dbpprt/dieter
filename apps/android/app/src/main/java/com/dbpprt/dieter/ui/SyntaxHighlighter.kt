package com.dbpprt.dieter.ui

import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation
import com.dbpprt.dieter.core.files.CodeLanguage
import com.dbpprt.dieter.core.files.MAX_EDITABLE_SYNTAX_HIGHLIGHT_CHARACTERS
import com.dbpprt.dieter.core.files.MAX_SYNTAX_HIGHLIGHT_CHARACTERS
import com.dbpprt.dieter.core.files.SyntaxKind
import com.dbpprt.dieter.core.files.codeLanguageForPath
import com.dbpprt.dieter.core.files.syntaxRanges
import com.dbpprt.dieter.ui.theme.DieterAmber
import com.dbpprt.dieter.ui.theme.DieterCoral
import com.dbpprt.dieter.ui.theme.DieterEyes
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterRunning

internal const val MaxSyntaxHighlightCharacters = MAX_SYNTAX_HIGHLIGHT_CHARACTERS
internal const val MaxEditableSyntaxHighlightCharacters = MAX_EDITABLE_SYNTAX_HIGHLIGHT_CHARACTERS

/** Editor highlighting: the core lexes, this maps its token kinds onto the Dieter palette. */
internal class CodeSyntaxVisualTransformation(
    path: String,
    private val characterLimit: Int = MaxSyntaxHighlightCharacters,
) : VisualTransformation {
    val language: CodeLanguage = codeLanguageForPath(path)
    private var cachedSource: String? = null
    private var cachedResult = AnnotatedString("")

    override fun filter(text: AnnotatedString): TransformedText {
        if (cachedSource != text.text) {
            cachedSource = text.text
            cachedResult = highlightedText(text.text, language, characterLimit)
        }
        return TransformedText(cachedResult, OffsetMapping.Identity)
    }
}

private fun highlightedText(source: String, language: CodeLanguage, characterLimit: Int): AnnotatedString {
    val builder = AnnotatedString.Builder(source)
    syntaxRanges(source, language, characterLimit).forEach { range ->
        builder.addStyle(styleFor(range.kind), range.start, range.end)
    }
    return builder.toAnnotatedString()
}

private fun styleFor(kind: SyntaxKind): SpanStyle = when (kind) {
    SyntaxKind.COMMENT -> SpanStyle(color = DieterMuted, fontStyle = FontStyle.Italic)
    SyntaxKind.STRING -> SpanStyle(color = DieterEyes)
    SyntaxKind.NUMBER -> SpanStyle(color = DieterCoral)
    SyntaxKind.KEYWORD -> SpanStyle(color = DieterRunning, fontWeight = FontWeight.SemiBold)
    SyntaxKind.TYPE -> SpanStyle(color = DieterAmber)
    SyntaxKind.FUNCTION -> SpanStyle(color = DieterRunning)
    SyntaxKind.ANNOTATION -> SpanStyle(color = DieterCoral)
    SyntaxKind.PROPERTY -> SpanStyle(color = DieterRunning)
    SyntaxKind.TAG -> SpanStyle(color = DieterRunning)
    SyntaxKind.ATTRIBUTE -> SpanStyle(color = DieterAmber)
    SyntaxKind.HEADING -> SpanStyle(color = DieterRunning, fontWeight = FontWeight.Bold)
    SyntaxKind.LINK -> SpanStyle(color = DieterRunning)
    SyntaxKind.EMPHASIS -> SpanStyle(color = DieterAmber, fontStyle = FontStyle.Italic)
    SyntaxKind.VARIABLE -> SpanStyle(color = DieterAmber)
    SyntaxKind.CONSTANT -> SpanStyle(color = DieterCoral)
}
