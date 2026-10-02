package com.dbpprt.dieter.core.presentation

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MarkdownAndLinksTest {
    @Test
    fun blankLinesSeparateParagraphsBulletsAndMultiLineFences() {
        val blocks = Markdown.parse(
            """
            ## Summary

            - Durable storage
            - Native Android client

            ```text
            go test ./...
            go vet ./...
            ```
            """.trimIndent(),
        )
        assertEquals(
            listOf(
                MarkdownBlock.Heading(2, "Summary"), MarkdownBlock.Bullet("Durable storage"), MarkdownBlock.Bullet("Native Android client"),
                MarkdownBlock.Code("go test ./...\ngo vet ./...", "text"),
            ),
            blocks,
        )
        assertEquals(listOf(MarkdownBlock.Paragraph("first line\nsecond line"), MarkdownBlock.Paragraph("next")), Markdown.parse("first line\nsecond line\n\nnext"))
        assertEquals(listOf(MarkdownBlock.Paragraph("##### too deep")), Markdown.parse("##### too deep"))
    }

    @Test
    fun pipeTablesNeedNoSurroundingBlankLines() {
        val blocks = Markdown.parse(
            """
            Snapshot at 21:33 CEST:
            | Node | CPU | GPU | Unified RAM |
            |---|---:|:---:|---|
            | gx10-c674 | ~6% | 96% | 115.7 GiB |
            | gx10-d6c4 | ~10% | 96% | 114.8 GiB |
            Available RAM remains low.
            """.trimIndent(),
        )
        assertEquals(3, blocks.size)
        assertEquals(MarkdownBlock.Paragraph("Snapshot at 21:33 CEST:"), blocks[0])
        val table = assertIs<MarkdownBlock.Table>(blocks[1])
        assertEquals(listOf("Node", "CPU", "GPU", "Unified RAM"), table.header)
        assertEquals(listOf(TableAlignment.START, TableAlignment.END, TableAlignment.CENTER, TableAlignment.START), table.alignments)
        assertEquals(listOf(listOf("gx10-c674", "~6%", "96%", "115.7 GiB"), listOf("gx10-d6c4", "~10%", "96%", "114.8 GiB")), table.rows)
        assertEquals(MarkdownBlock.Paragraph("Available RAM remains low."), blocks[2])

        val ragged = assertIs<MarkdownBlock.Table>(Markdown.parse("| a | b |\n| --- | --- |\n| only |\n| 1 | 2 | 3 |").single())
        assertEquals(listOf(listOf("only", ""), listOf("1", "2")), ragged.rows, "rows are fitted to the header")
        assertEquals(listOf(MarkdownBlock.Paragraph("a | b\n| - | - |")), Markdown.parse("a | b\n| - | - |"), "a delimiter needs three dashes")
    }

    @Test
    fun workspaceImageLinksStayInsideTheWorkspace() {
        val root = "/remote/worktree"
        assertTrue(WorkspaceImages.isWorkspaceImage("file:///remote/worktree/docs/result.png"))
        assertTrue(WorkspaceImages.isWorkspaceImage("../candidate.png"), "containment is checked while resolving the path")
        assertFalse(WorkspaceImages.isWorkspaceImage("https://example.com/result.png"))
        assertFalse(WorkspaceImages.isWorkspaceImage("README.md"))
        assertEquals("docs/screenshots/Preview One.PNG", WorkspaceImages.path("./docs/screenshots/Preview%20One.PNG#view"))
        assertEquals("images/result.webp", WorkspaceImages.path("images/result.webp"))
        assertEquals("docs/result.png", WorkspaceImages.path("file:///remote/worktree/docs/result.png", root))
        assertEquals("docs/result.png", WorkspaceImages.path("file://localhost/remote/worktree/docs/result.png", "$root/"))
        assertEquals("docs/Preview One.png", WorkspaceImages.path("</remote/worktree/docs/Preview One.png>", root))
        assertNull(WorkspaceImages.path("/absolute/image.png"), "an absolute path needs the workspace root")
        assertNull(WorkspaceImages.path("/remote/worktree/docs/result.png", "relative/root"))
        assertNull(WorkspaceImages.path("file:///remote/other/image.png", root))
        assertNull(WorkspaceImages.path("/remote/worktree-other/image.png", root), "a sibling sharing the root's prefix is outside")
        assertNull(WorkspaceImages.path("file:///remote/worktree/../secret.png", root))
        assertNull(WorkspaceImages.path("docs/../../secret.png"))
        assertNull(WorkspaceImages.path("ftp://example.com/image.png"))
        assertNull(WorkspaceImages.path("file://otherhost/remote/worktree/image.png", root), "another machine's file is never read")
        assertEquals("C++ notes/diagram+1.png", WorkspaceImages.path("C++%20notes/diagram+1.png"), "a plus in a path stays a plus")
        assertNull(WorkspaceImages.path("README.md"))
    }

    @Test
    fun developmentAddressesInProseBecomeWebLinks() {
        val match = DetectedLinks.find("Served at localhost:8080.").single()
        assertEquals("http://localhost:8080", match.url)
        assertEquals(10 until 24, match.range)
        assertEquals(
            listOf("http://[::1]:5173/app", "http://localhost:3000/a_(b)"),
            DetectedLinks.find("Try [::1]:5173/app or (localhost:3000/a_(b)).").map { it.url },
        )
        assertTrue(DetectedLinks.find("host.localhost:3000 and user@localhost:22").isEmpty())
    }
}
