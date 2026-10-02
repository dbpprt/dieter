package com.dbpprt.dieter.core.composition

import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.core.presentation.ByteSizes
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import okio.ByteString.Companion.toByteString

class AttachmentsTest {
    private fun bytes(count: Int) = ByteArray(count).toByteString()

    @Test
    fun chipsShowTheFileTypeAndSize() {
        assertEquals("PDF · 1.0 MB", Attachments.details(MessagePart(type = "file", filename = "brief.pdf", media_type = "application/pdf", data_ = bytes(1024 * 1024))))
        assertEquals("PNG · 1.2 MB", Attachments.details(MessagePart(type = "file", filename = "shot.png", media_type = "image/png", data_ = bytes(1_258_291))))
        assertEquals("SVG · 512 B", Attachments.details(MessagePart(type = "file", media_type = "image/svg+xml", data_ = bytes(512))), "an unnamed file uses its media type")
        assertEquals("PDF", Attachments.details(MessagePart(type = "file", filename = "brief.pdf")), "an empty file shows no size")
        assertEquals("PNG image", Attachments.kind(MessagePart(filename = "shot.png", media_type = "image/png")))
        assertEquals("Image", Attachments.kind(MessagePart(media_type = "image/png")))
        assertEquals("File", Attachments.kind(MessagePart(media_type = Attachments.OCTET_STREAM)))
    }

    @Test
    fun chipDetailsFromMeasuredFiles() {
        assertEquals("PDF · 1.5 KB", Attachments.details("brief.pdf", "application/pdf", 1_536))
        assertEquals("SVG · 240 MB", Attachments.details("", "image/svg+xml", 240L * 1024 * 1024), "a media type suffix is dropped")
        assertEquals("FILE", Attachments.details("", "", 0), "no name, type, or size")
        assertEquals("PNG", Attachments.details("shot.png", "image/png", 0), "an empty file shows no size")
    }

    @Test
    fun measuredFilesHitTheSameLimitsInTheSameOrder() {
        val mb = 1024L * 1024
        assertNull(Attachments.limitError(emptyList(), emptyList()))
        assertNull(Attachments.limitError(List(4) { "f$it" }, List(4) { mb }))
        assertEquals("You can attach up to 4 images or files.", Attachments.limitError(List(5) { "f$it" }, List(5) { 0L }), "the count comes first")
        assertEquals("b.txt is empty.", Attachments.limitError(listOf("a.txt", "b.txt"), listOf(1L, 0L)))
        assertEquals("The attachment is empty.", Attachments.limitError(emptyList(), listOf(0L)), "a missing name reads generically")
        assertEquals("Each attachment must be at most 5 MB.", Attachments.limitError(listOf("big.mov"), listOf(5 * mb + 1)))
        assertEquals("Attachments must total at most 6 MB.", Attachments.limitError(listOf("a", "b"), listOf(4 * mb, 3 * mb)))
        assertEquals(
            listOf(Attachments.TOO_MANY, Attachments.FILE_TOO_LARGE, Attachments.TOTAL_TOO_LARGE),
            listOf(Attachments.limitError(List(5) { "f$it" }, List(5) { 1L }), Attachments.limitError(listOf("big.mov"), listOf(5 * mb + 1)), Attachments.limitError(listOf("a", "b"), listOf(4 * mb, 3 * mb))),
            "platforms reading a file past the limit say the same",
        )
        assertEquals("Up to 4 attachments · 5 MB each · 6 MB total", Attachments.LIMITS)
    }

    @Test
    fun dataUrlSizesAreTheDecodedPayload() {
        assertEquals(2L, Attachments.size(MessagePart(url = "data:text/plain;base64,aGk=")))
        assertEquals(5L, Attachments.size(MessagePart(url = "data:text/plain,hello")))
        assertEquals(0L, Attachments.size(MessagePart(url = "https://example.com/a.png")))
    }

    @Test
    fun byteSizesUseBinaryUnitsIndependentOfTheLocale() {
        assertEquals(
            listOf("0 B", "1023 B", "1.0 KB", "1.5 KB", "150 KB", "240 MB", "1.0 GB", "0 B"),
            listOf(0L, 1023L, 1024L, 1536L, 150L * 1024, 240L * 1024 * 1024, 1024L * 1024 * 1024, -5L).map(ByteSizes::format),
        )
    }
}
