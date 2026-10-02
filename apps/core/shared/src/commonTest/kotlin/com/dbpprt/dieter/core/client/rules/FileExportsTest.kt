package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.api.v1.FileDocument
import com.dbpprt.dieter.client.v1.FileIconKind
import com.dbpprt.dieter.client.v1.FileRenderer
import com.dbpprt.dieter.client.v1.SyntaxHighlights
import com.dbpprt.dieter.client.v1.SyntaxKind
import com.dbpprt.dieter.core.client.filesSlice
import com.dbpprt.dieter.core.files.FilesTarget
import com.dbpprt.dieter.core.files.FilesView
import com.dbpprt.dieter.core.files.MAX_SYNTAX_HIGHLIGHT_CHARACTERS
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class FileExportsTest {
    private fun spans(text: String, path: String, offset: Int = 0): List<Triple<Int, Int, SyntaxKind?>> {
        val decoded = SyntaxHighlights.ADAPTER.decode(SyntaxHighlights.ADAPTER.encode(FileExports.syntaxHighlights(text, path, offset)))
        return decoded.spans.chunked(3).map { (start, length, kind) -> Triple(start, length, SyntaxKind.fromValue(kind)) }
    }

    @Test
    fun highlightsArePackedUtf16TriplesShiftedByTheOffset() {
        assertEquals(
            listOf(
                Triple(100, 3, SyntaxKind.SYNTAX_KIND_KEYWORD),
                Triple(108, 1, SyntaxKind.SYNTAX_KIND_NUMBER),
                Triple(110, 7, SyntaxKind.SYNTAX_KIND_COMMENT),
            ),
            spans("let x = 1 // note", "Sources/A.swift", offset = 100),
        )
        // Ported from the macOS highlight plan test.
        val kinds = spans("let answer: Int = 42 // meaning", "main.swift").map { it.third }
        assertTrue(SyntaxKind.SYNTAX_KIND_KEYWORD in kinds && SyntaxKind.SYNTAX_KIND_NUMBER in kinds && SyntaxKind.SYNTAX_KIND_COMMENT in kinds)
    }

    @Test
    fun markdownHeadingsStartAtTheirLineAndCountSurrogatePairs() {
        // The Mac paints headings in its keyword color; the editor tests read offset 0.
        val heading = spans("# Updated 💡\n\n**Bold**", "README.md").first()
        assertEquals(Triple(0, "# Updated 💡".length, SyntaxKind.SYNTAX_KIND_HEADING), heading)
        assertEquals(12, heading.second, "the emoji is two UTF-16 units")
    }

    @Test
    fun plainTextAndTextBeyondTheLimitStayUnhighlighted() {
        assertTrue(spans("Copyright 2026 \"Dieter\" Example(1)", "LICENSE").isEmpty())
        assertTrue(spans("x".repeat(MAX_SYNTAX_HIGHLIGHT_CHARACTERS) + "\n// tail", "main.swift").isEmpty())
    }

    @Test
    fun lineRangesPackStartAndLength() {
        assertEquals((4L shl 32) or 3L, FileExports.lineRange("ab\r\ncde\nf", 2))
        assertEquals((8L shl 32) or 1L, FileExports.lineRange("ab\r\ncde\nf", 99))
        assertEquals(0L, FileExports.lineRange("", 1))
        assertEquals(2L shl 32, FileExports.lineRange("a\n", 3))
        assertEquals(1, FileExports.lineCount(""))
        assertEquals(3, FileExports.lineCount("one\ntwo\nthree"))
    }

    @Test
    fun languagesRenderersAndIcons() {
        assertEquals(FileRenderer.FILE_RENDERER_PDF, FileExports.renderer("report.PDF", "", true))
        assertEquals(FileRenderer.FILE_RENDERER_MARKDOWN, FileExports.renderer("docs/plan.md", "text/markdown", false))
        assertEquals(FileRenderer.FILE_RENDERER_UNSUPPORTED, FileExports.renderer("content-preview.bin", "application/octet-stream", true))
        assertEquals(FileRenderer.FILE_RENDERER_UNSPECIFIED, FileExports.renderer(null))
        assertEquals(FileIconKind.FILE_ICON_KIND_DIRECTORY, FileExports.iconKind("Sources", true))
        assertEquals(FileIconKind.FILE_ICON_KIND_IMAGE, FileExports.iconKind("logo.svg", false))
        assertEquals(FileIconKind.FILE_ICON_KIND_MARKDOWN, FileExports.iconKind("README.md", false))
        assertEquals(FileIconKind.FILE_ICON_KIND_CODE, FileExports.iconKind("main.go", false))
        assertEquals(FileIconKind.FILE_ICON_KIND_TEXT, FileExports.iconKind("notes.txt", false))
    }

    @Test
    fun theFilesSliceDescribesTheOpenDocumentEvenWhenItIsLeftOut() {
        val target = FilesTarget("daemon", "project", cardId = "card")
        val view = FilesView(target = target, selectedPath = "src/main.swift", document = FileDocument(path = "src/main.swift", name = "main.swift", mime_type = "text/x-swift", content = "let x = 1"))
        val slice = filesSlice(view, documentUnchanged = true)
        assertNull(slice.document)
        assertEquals(target.documentKey("src/main.swift"), slice.document_key)
        assertEquals("Swift", slice.language_name)
        assertEquals("text/x-swift", slice.type_label)
        val closed = filesSlice(FilesView(target = target), documentUnchanged = false)
        assertEquals("", closed.language_name)
        assertEquals("", closed.type_label)
        assertEquals(target.documentKey(""), closed.document_key)
    }
}
