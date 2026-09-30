package com.dbpprt.dieter.core.composition

import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.core.presentation.ByteSizes
import kotlin.test.Test
import kotlin.test.assertEquals
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
