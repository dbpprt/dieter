package com.getdieter.core.presentation

import kotlin.test.Test
import kotlin.test.assertTrue
import kotlin.time.measureTime

/** A mail body may be 128 KiB; parsing it with every inline tree stays well under 100 ms. */
class MarkdownPerformanceTest {
    @Test
    fun aMaximalBodyParsesQuickly() {
        val report = markdownFixture("mail-report.md")
        val table = markdownFixture("table-1000-rows.md")
        val source = buildString {
            while (length < 128 * 1024) {
                append(report).append("\n")
                append(markdownFixture("emphasis.md")).append("\n")
                append(markdownFixture("links.md")).append("\n")
                append(markdownFixture("lists.md")).append("\n")
                if (length < 64 * 1024) append(table).append("\n")
            }
        }
            .take(128 * 1024)
        repeat(5) { parseFully(source) }
        val fastest = (1..5).minOf { measureTime { parseFully(source) } }
        assertTrue(fastest.inWholeMilliseconds < 100, "128 KiB took $fastest")
        println("MarkdownPerformanceTest: 128 KiB in $fastest")
    }

    /** Blocks plus every inline tree, as a renderer showing the whole document would. */
    private fun parseFully(source: String): Int {
        var spans = 0
        fun visit(blocks: List<MarkdownBlock>) {
            for (block in blocks) {
                when (block) {
                    is MarkdownBlock.Paragraph -> spans += block.inlines.size
                    is MarkdownBlock.Heading -> spans += block.inlines.size
                    is MarkdownBlock.Quote -> visit(block.blocks)
                    is MarkdownBlock.ListBlock -> block.items.forEach { visit(it.blocks) }
                    is MarkdownBlock.Table ->
                        (listOf(block.header) + block.rows).forEach { row ->
                            row.forEach { spans += Markdown.inline(it).size }
                        }
                    is MarkdownBlock.Code,
                    MarkdownBlock.Rule -> spans++
                }
            }
        }
        visit(Markdown.parse(source))
        return spans
    }
}
