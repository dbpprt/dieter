package com.getdieter.core.presentation

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** The base names of the golden corpus documents in tests/fixtures/markdown. */
internal expect fun markdownFixtureNames(): List<String>

/** A corpus file's text, e.g. `tables.md` or `tables.json`. */
internal expect fun markdownFixture(file: String): String

/**
 * The golden corpus (tests/fixtures/markdown): every `NAME.md` parses to the block tree in
 * `NAME.json`, inline trees included. The Mac and Compose renderers show the same documents.
 */
class MarkdownCorpusTest {
    @Test
    fun everyDocumentParsesToItsExpectedTree() {
        val names = markdownFixtureNames()
        assertTrue(
            names.containsAll(
                listOf(
                    "headings",
                    "paragraphs",
                    "emphasis",
                    "links",
                    "lists",
                    "tasks",
                    "quotes",
                    "rules",
                    "code",
                    "tables",
                    "table-30-columns",
                    "table-1000-rows",
                    "edge-cases",
                    "mail-report",
                )
            ),
            "corpus: $names",
        )
        for (name in names) {
            val actual = MarkdownJson.blocks(Markdown.parse(markdownFixture("$name.md")))
            val expected = Json.parseToJsonElement(markdownFixture("$name.json"))
            assertEquals(expected, actual, "$name.md parsed to\n${MarkdownJson.pretty(actual)}")
        }
    }
}

/**
 * The corpus's JSON form of a block tree. A text inline is a string; every other node is an object
 * named by its kind.
 */
internal object MarkdownJson {
    private val printer = Json {
        prettyPrint = true
        prettyPrintIndent = "  "
    }

    fun pretty(element: JsonElement): String =
        printer.encodeToString(JsonElement.serializer(), element)

    fun blocks(blocks: List<MarkdownBlock>): JsonArray = JsonArray(blocks.map(::block))

    private fun block(block: MarkdownBlock): JsonElement =
        when (block) {
            is MarkdownBlock.Paragraph ->
                buildJsonObject { put("paragraph", inlines(block.inlines)) }
            is MarkdownBlock.Heading ->
                buildJsonObject {
                    put("heading", block.level)
                    put("inlines", inlines(block.inlines))
                }
            is MarkdownBlock.Code ->
                buildJsonObject {
                    put("code", block.text)
                    put("language", block.language)
                }
            is MarkdownBlock.Quote -> buildJsonObject { put("quote", blocks(block.blocks)) }
            is MarkdownBlock.ListBlock ->
                buildJsonObject {
                    put("list", if (block.ordered) "ordered" else "bullet")
                    if (block.ordered) put("start", block.start)
                    put(
                        "items",
                        JsonArray(
                            block.items.map { item ->
                                buildJsonObject {
                                    item.checked?.let { put("checked", it) }
                                    put("blocks", blocks(item.blocks))
                                }
                            }
                        ),
                    )
                }
            MarkdownBlock.Rule -> buildJsonObject { put("rule", true) }
            is MarkdownBlock.Table ->
                buildJsonObject {
                    put(
                        "table",
                        buildJsonObject {
                            put(
                                "alignments",
                                JsonArray(
                                    block.alignments.map { JsonPrimitive(it.name.lowercase()) }
                                ),
                            )
                            put("header", JsonArray(block.header.map(::cell)))
                            put(
                                "rows",
                                JsonArray(block.rows.map { row -> JsonArray(row.map(::cell)) }),
                            )
                        },
                    )
                }
        }

    private fun cell(source: String): JsonArray = inlines(Markdown.inline(source))

    fun inlines(inlines: List<MarkdownInline>): JsonArray = JsonArray(inlines.map(::inline))

    private fun inline(inline: MarkdownInline): JsonElement =
        when (inline) {
            is MarkdownInline.Text -> JsonPrimitive(inline.text)
            is MarkdownInline.Code -> buildJsonObject { put("code", inline.text) }
            is MarkdownInline.Emphasis ->
                buildJsonObject { put("emphasis", inlines(inline.children)) }
            is MarkdownInline.Strong -> buildJsonObject { put("strong", inlines(inline.children)) }
            is MarkdownInline.Strikethrough ->
                buildJsonObject { put("strikethrough", inlines(inline.children)) }
            is MarkdownInline.Link ->
                buildJsonObject {
                    put("link", inline.url)
                    put("text", inlines(inline.children))
                    if (inline.autolink) put("autolink", true)
                }
            is MarkdownInline.Image ->
                buildJsonObject {
                    put("image", inline.url)
                    put("alt", inline.alt)
                }
            is MarkdownInline.Break ->
                buildJsonObject { put("break", if (inline.hard) "hard" else "soft") }
        }
}
