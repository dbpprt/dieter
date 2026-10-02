package com.dbpprt.dieter.core.presentation

import com.dbpprt.dieter.api.v1.Harness
import com.dbpprt.dieter.api.v1.HarnessCatalog
import com.dbpprt.dieter.api.v1.HarnessModel
import com.dbpprt.dieter.api.v1.TokenUsage
import com.dbpprt.dieter.api.v1.UiMessage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Instant
import okio.ByteString.Companion.encodeUtf8

class UsageTest {
    private fun message(metadata: String) = UiMessage(id = "m", role = "assistant", metadata_json = metadata.encodeUtf8())

    @Test
    fun contextUsageComesFromTheLatestReportingStep() {
        val usage = ContextUsage.latest(listOf(message("""{"usage":{"totalTokens":150},"contextWindowTokens":1000,"modelId":"sol"}"""), UiMessage(id = "b")))!!
        assertEquals(15, usage.percent)
        assertEquals("sol", usage.modelId)
        assertEquals(1000, ContextUsage.latest(listOf(message("""{"usage":{"inputTokens":10,"outputTokens":5}}""")), fallbackWindow = 1000)!!.windowTokens)
        assertNull(ContextUsage.latest(listOf(message("""{"usage":{"totalTokens":5}}"""))))
        assertTrue(ContextUsage(900, 1000, null).nearLimit)
        val malformed = ContextUsage.latest(listOf(message("""{"usage":{"totalTokens":150,"raw":{"totalTokens":{}}},"contextWindowTokens":1000,"modelId":{}}""")))!!
        assertEquals(150, malformed.usedTokens, "a malformed member is unknown")
        assertNull(malformed.modelId)
    }

    @Test
    fun contextWindowsComeFromTheReportedModelThenTheSelection() {
        // Ported from the Mac's conversationContextUsageReadsHarnessMetadata, which read
        // only the newest message with metadata; the core keeps the last reported step.
        val reported = ContextUsage.latest(listOf(message("""{"usage":{"inputTokens":120,"outputTokens":30,"totalTokens":150},"contextWindowTokens":1000}""")))!!
        assertEquals(150, reported.usedTokens)
        assertEquals(1_000, reported.windowTokens)
        assertEquals(15, reported.percent)
        val later = UiMessage(id = "u", role = "user", metadata_json = """{"createdAt":"2026-09-30T10:00:00Z"}""".encodeUtf8())
        assertEquals(150L, ContextUsage.latest(listOf(message("""{"usage":{"totalTokens":150},"contextWindowTokens":1000}"""), later))?.usedTokens, "a newer message without usage does not hide it")
        val asked = mutableListOf<String?>()
        val fallback = ContextUsage.latest(listOf(message("""{"usage":{"totalTokens":150},"modelId":"luna","contextWindowTokens":0}"""))) { model -> asked += model; 3_000 }!!
        assertEquals(3_000, fallback.windowTokens, "an explicit 0 window falls back to the catalog")
        assertEquals(listOf<String?>("luna"), asked)
        assertNull(ContextUsage.latest(listOf(message("""{"usage":{"totalTokens":0},"contextWindowTokens":1000}"""))), "nothing used, nothing to show")

        val catalog = HarnessCatalog(
            harnesses = listOf(Harness(id = "codex", default_model = "sol", models = listOf(HarnessModel(id = "sol", context_window = 200_000), HarnessModel(id = "luna", context_window = 400_000), HarnessModel(id = "unknown")))),
        )
        assertEquals(400_000, ContextUsage.catalogWindow(catalog, "codex", "luna", "sol"))
        assertEquals(200_000, ContextUsage.catalogWindow(catalog, "codex", "claude-opus-4-1", "sol"), "an unlisted reported model falls back to the selection")
        assertEquals(200_000, ContextUsage.catalogWindow(catalog, "codex", null, ""), "an empty selection is the harness default")
        assertEquals(200_000, ContextUsage.catalogWindow(catalog, "codex", "unknown", ""), "a listed model without a window falls back too")
        assertEquals(0, ContextUsage.catalogWindow(catalog, "claude-code", "luna", "luna"))
        assertEquals(0, ContextUsage.catalogWindow(null, "codex", "luna", "luna"))
    }

    @Test
    fun metadataIsReadOneWayForEveryMessage() {
        assertEquals(Instant.parse("2026-09-30T10:00:00Z"), MessageMetadata.createdAt(message("""{"createdAt":"2026-09-30T10:00:00Z"}""")))
        for (malformed in listOf("", "not json", "[1]", "\"text\"", """{"createdAt":42}""", """{"createdAt":{}}""", """{"createdAt":null}""", """{"createdAt":"soon"}""")) {
            assertNull(MessageMetadata.createdAt(message(malformed)), malformed)
        }
        assertNull(MessageMetadata.of(message("[1]")))
        val metadata = MessageMetadata.of(message("""{"modelId":"sol","count":1}"""))
        assertEquals("sol", MessageMetadata.string(metadata, "modelId"))
        assertNull(MessageMetadata.string(metadata, "count"), "only strings read as strings")
        assertNull(MessageMetadata.string(null, "modelId"))
    }

    @Test
    fun tokenCountsReadTheSameEverywhere() {
        assertEquals(listOf("999", "1.2k", "99.9k", "129k", "1.3M"), listOf(999L, 1_234L, 99_949L, 128_953L, 1_288_847L).map(TokenCounts::compact))
        assertEquals("Tokens unavailable", TokenUsagePresentation(TokenUsage()).label())
        assertEquals("125 tokens · partial", TokenUsagePresentation(TokenUsage(total_tokens = 125, reported_messages = 1, partial = true)).label())
        assertEquals("1.2k tokens", TokenUsagePresentation(TokenUsage(total_tokens = 1_234, reported_messages = 2)).label())
        assertEquals("129k tokens", TokenUsagePresentation(TokenUsage(total_tokens = 128_953, reported_messages = 2)).label())
        assertEquals("Tokens unavailable", TokenCounts.label(totalTokens = 1_250, reportedMessages = 0, partial = true), "missing reports are unavailable, partial or not")
        assertEquals("1.3k tokens · partial", TokenCounts.label(totalTokens = 1_250, reportedMessages = 2, partial = true), "ties round up")
        assertEquals("1.3M tokens", TokenCounts.label(totalTokens = 1_288_847, reportedMessages = 1, partial = false))

        assertEquals("Token usage was not reported by the provider.", TokenCounts.detail(TokenUsage(missing_messages = 1, partial = true)))
        val partial = TokenUsage(reported_messages = 1, input_tokens = 100, output_tokens = 25, total_tokens = 125, partial = true)
        assertTrue(TokenCounts.detail(partial).startsWith("125 total tokens · 100 input · 25 output. Partial provider data"))
        assertFalse(TokenCounts.detail(partial.copy(partial = false)).contains("Partial"))
    }
}
