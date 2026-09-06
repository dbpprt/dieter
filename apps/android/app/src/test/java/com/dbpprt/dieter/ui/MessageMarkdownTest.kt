package com.dbpprt.dieter.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MessageMarkdownTest {
    @Test
    fun separatesParagraphsBulletsAndCodeFences() {
        val blocks = parseMessageMarkdown(
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

        assertEquals(listOf("Summary", "• Durable storage", "• Native Android client", "go test ./...\ngo vet ./..."), blocks.map { it.text })
        assertEquals(2, blocks.first().headingLevel)
        assertFalse(blocks.first().code)
        assertTrue(blocks.last().code)
    }

    @Test
    fun removesInlineMarkdownDelimitersFromVisibleText() {
        assertEquals(
            "Use internal/store and README for details.",
            markdownInlineText("Use `internal/store` and [README](README.md) for **details**.").text,
        )
    }

    @Test
    fun recognizesPipeTableWithoutSurroundingBlankLines() {
        val blocks = parseMessageMarkdown(
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
        assertEquals("Snapshot at 21:33 CEST:", blocks[0].text)
        assertEquals(listOf("Node", "CPU", "GPU", "Unified RAM"), blocks[1].table?.headers)
        assertEquals(
            listOf(
                MessageMarkdownAlignment.START,
                MessageMarkdownAlignment.END,
                MessageMarkdownAlignment.CENTER,
                MessageMarkdownAlignment.START,
            ),
            blocks[1].table?.alignments,
        )
        assertEquals(listOf("gx10-c674", "~6%", "96%", "115.7 GiB"), blocks[1].table?.rows?.first())
        assertEquals("Available RAM remains low.", blocks[2].text)
    }

    @Test
    fun keepsEscapedAndCodeSpanPipesInsideTableCells() {
        assertEquals(
            listOf("name", "a|b", "`x|y`"),
            markdownTableCells("| name | a\\|b | `x|y` |"),
        )
    }
}
