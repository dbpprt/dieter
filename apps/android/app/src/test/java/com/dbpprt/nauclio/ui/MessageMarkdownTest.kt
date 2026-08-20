package com.dbpprt.nauclio.ui

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
}
