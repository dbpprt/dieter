package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.MessagePart
import com.google.protobuf.ByteString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ComposerAttachmentsTest {
    @Test
    fun acceptsMixedImagesAndDocumentsWithinLimits() {
        val current = listOf(part("photo.jpg", "image/jpeg", 512 * 1024))
        val incoming = listOf(part("brief.pdf", "application/pdf", 1024 * 1024))

        assertNull(attachmentLimitError(current, incoming))
        assertEquals("PDF · 1.0 MB", attachmentDetails(incoming.single()))
    }

    @Test
    fun rejectsMoreThanFourAttachments() {
        val current = List(3) { part("$it.txt", "text/plain", 1) }
        val incoming = List(2) { part("new-$it.txt", "text/plain", 1) }

        assertTrue(attachmentLimitError(current, incoming).orEmpty().contains("up to 4"))
    }

    @Test
    fun rejectsAttachmentsOverTheCombinedLimit() {
        val current = listOf(part("first.bin", "application/octet-stream", 3 * 1024 * 1024))
        val incoming = listOf(part("second.bin", "application/octet-stream", 3 * 1024 * 1024 + 1))

        assertTrue(attachmentLimitError(current, incoming).orEmpty().contains("6 MB"))
    }

    @Test
    fun calculatesPaddedDataUrlSizes() {
        val value = MessagePart.newBuilder()
            .setType("file")
            .setMediaType("text/plain")
            .setUrl("data:text/plain;base64,aGVsbG8=")
            .build()

        assertEquals(5, attachmentSize(value))
    }

    private fun part(filename: String, mediaType: String, size: Int): MessagePart = MessagePart.newBuilder()
        .setType("file")
        .setFilename(filename)
        .setMediaType(mediaType)
        .setData(ByteString.copyFrom(ByteArray(size)))
        .build()
}
