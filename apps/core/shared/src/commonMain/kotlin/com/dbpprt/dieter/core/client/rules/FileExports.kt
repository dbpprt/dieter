package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.client.v1.FileIconKind
import com.dbpprt.dieter.client.v1.FileRenderer
import com.dbpprt.dieter.client.v1.SyntaxHighlights
import com.dbpprt.dieter.client.v1.SyntaxKind as SyntaxKindValue
import com.dbpprt.dieter.core.files.FilePaths
import com.dbpprt.dieter.core.files.MAX_SYNTAX_HIGHLIGHT_CHARACTERS
import com.dbpprt.dieter.core.files.SyntaxKind
import com.dbpprt.dieter.core.files.codeLanguageForPath
import com.dbpprt.dieter.core.files.syntaxRanges

/**
 * File presentation as editors and listings call it while rendering:
 * languages, syntax highlighting, line ranges, renderers, and icons. Offsets
 * and lengths are UTF-16 code units, as NSString and Kotlin strings count.
 */
object FileExports {
    /**
     * Highlight spans for the first 200,000 characters of [text], in the
     * language of [path], as (start, length, kind) triples with starts shifted
     * by [offset]: an editor passes an edited line range and its document
     * offset, or the whole document and 0. Later spans win where they overlap.
     */
    fun syntaxHighlights(text: String, path: String, offset: Int): SyntaxHighlights {
        val ranges = syntaxRanges(text, codeLanguageForPath(path), MAX_SYNTAX_HIGHLIGHT_CHARACTERS)
        val spans = ArrayList<Int>(ranges.size * 3)
        for (range in ranges) {
            if (range.end <= range.start) continue
            spans += range.start + offset
            spans += range.end - range.start
            spans += kind(range.kind).value
        }
        return SyntaxHighlights(spans = spans)
    }

    /**
     * The UTF-16 range of 1-based [line] in [text] without its terminator, as
     * `start shl 32 or length`; `\n`, `\r`, and `\r\n` end a line and
     * out-of-range lines clamp to the first or last.
     */
    fun lineRange(text: String, line: Int): Long {
        val range = FilePaths.lineRange(line, text)
        return (range.first.toLong() shl 32) or (range.last + 1 - range.first).toLong()
    }

    /** One more than the number of line feeds: "" is one line. */
    fun lineCount(text: String): Int = FilePaths.countLines(text)

    /** How to show a file with this name or path, media type, and binary flag. */
    fun renderer(path: String, mimeType: String, binary: Boolean): FileRenderer = renderer(FilePaths.renderer(path, mimeType, binary))

    /** A listing row's icon kind for a file or folder [name]. */
    fun iconKind(name: String, directory: Boolean): FileIconKind = when (FilePaths.icon(name, directory)) {
        FilePaths.Icon.DIRECTORY -> FileIconKind.FILE_ICON_KIND_DIRECTORY
        FilePaths.Icon.IMAGE -> FileIconKind.FILE_ICON_KIND_IMAGE
        FilePaths.Icon.MARKDOWN -> FileIconKind.FILE_ICON_KIND_MARKDOWN
        FilePaths.Icon.CODE -> FileIconKind.FILE_ICON_KIND_CODE
        FilePaths.Icon.TEXT -> FileIconKind.FILE_ICON_KIND_TEXT
    }

    internal fun renderer(value: FilePaths.Renderer?): FileRenderer = when (value) {
        null -> FileRenderer.FILE_RENDERER_UNSPECIFIED
        FilePaths.Renderer.TEXT -> FileRenderer.FILE_RENDERER_TEXT
        FilePaths.Renderer.MARKDOWN -> FileRenderer.FILE_RENDERER_MARKDOWN
        FilePaths.Renderer.IMAGE -> FileRenderer.FILE_RENDERER_IMAGE
        FilePaths.Renderer.PDF -> FileRenderer.FILE_RENDERER_PDF
        FilePaths.Renderer.UNSUPPORTED -> FileRenderer.FILE_RENDERER_UNSUPPORTED
    }

    private fun kind(kind: SyntaxKind): SyntaxKindValue = when (kind) {
        SyntaxKind.COMMENT -> SyntaxKindValue.SYNTAX_KIND_COMMENT
        SyntaxKind.STRING -> SyntaxKindValue.SYNTAX_KIND_STRING
        SyntaxKind.NUMBER -> SyntaxKindValue.SYNTAX_KIND_NUMBER
        SyntaxKind.KEYWORD -> SyntaxKindValue.SYNTAX_KIND_KEYWORD
        SyntaxKind.TYPE -> SyntaxKindValue.SYNTAX_KIND_TYPE
        SyntaxKind.FUNCTION -> SyntaxKindValue.SYNTAX_KIND_FUNCTION
        SyntaxKind.ANNOTATION -> SyntaxKindValue.SYNTAX_KIND_ANNOTATION
        SyntaxKind.PROPERTY -> SyntaxKindValue.SYNTAX_KIND_PROPERTY
        SyntaxKind.TAG -> SyntaxKindValue.SYNTAX_KIND_TAG
        SyntaxKind.ATTRIBUTE -> SyntaxKindValue.SYNTAX_KIND_ATTRIBUTE
        SyntaxKind.HEADING -> SyntaxKindValue.SYNTAX_KIND_HEADING
        SyntaxKind.LINK -> SyntaxKindValue.SYNTAX_KIND_LINK
        SyntaxKind.EMPHASIS -> SyntaxKindValue.SYNTAX_KIND_EMPHASIS
        SyntaxKind.VARIABLE -> SyntaxKindValue.SYNTAX_KIND_VARIABLE
        SyntaxKind.CONSTANT -> SyntaxKindValue.SYNTAX_KIND_CONSTANT
    }
}
