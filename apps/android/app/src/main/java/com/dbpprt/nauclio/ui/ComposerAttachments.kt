package com.dbpprt.nauclio.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import com.dbpprt.nauclio.v1.MessagePart
import com.google.protobuf.ByteString
import java.io.ByteArrayOutputStream
import java.util.Base64
import java.util.Locale

internal const val MAX_COMPOSER_ATTACHMENTS = 4
internal const val MAX_COMPOSER_ATTACHMENT_BYTES = 5 * 1024 * 1024
internal const val MAX_COMPOSER_TOTAL_BYTES = 6 * 1024 * 1024

internal fun readAttachmentPart(context: Context, uri: Uri, imagesOnly: Boolean): MessagePart {
    val resolver = context.contentResolver
    var filename = ""
    var declaredSize = -1L
    resolver.query(
        uri,
        arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
        null,
        null,
        null,
    )?.use { cursor ->
        if (cursor.moveToFirst()) {
            filename = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                .takeIf { it >= 0 }
                ?.let(cursor::getString)
                .orEmpty()
            declaredSize = cursor.getColumnIndex(OpenableColumns.SIZE)
                .takeIf { it >= 0 && !cursor.isNull(it) }
                ?.let(cursor::getLong)
                ?: -1L
        }
    }
    val mediaType = resolver.getType(uri)
        ?.substringBefore(';')
        ?.trim()
        ?.lowercase(Locale.ROOT)
        ?.takeIf { it.contains('/') }
        ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(
            filename.substringAfterLast('.', "").lowercase(Locale.ROOT),
        )
        ?: "application/octet-stream"
    require(!imagesOnly || mediaType.startsWith("image/")) { "Choose an image file" }
    require(declaredSize <= MAX_COMPOSER_ATTACHMENT_BYTES || declaredSize < 0) {
        "Each attachment must be at most 5 MB"
    }
    val bytes = requireNotNull(resolver.openInputStream(uri)) { "Could not open attachment" }.use { input ->
        val output = ByteArrayOutputStream(
            declaredSize.takeIf { it in 1..MAX_COMPOSER_ATTACHMENT_BYTES.toLong() }?.toInt() ?: 32 * 1024,
        )
        val buffer = ByteArray(16 * 1024)
        var total = 0
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            total += read
            require(total <= MAX_COMPOSER_ATTACHMENT_BYTES) { "Each attachment must be at most 5 MB" }
            output.write(buffer, 0, read)
        }
        output.toByteArray()
    }
    require(bytes.isNotEmpty()) { "Attachment is empty" }
    val fallbackName = if (mediaType.startsWith("image/")) "attached-image" else "attachment"
    return MessagePart.newBuilder()
        .setType("file")
        .setMediaType(mediaType)
        .setFilename(filename.trim().ifBlank { fallbackName })
        .setData(ByteString.copyFrom(bytes))
        .build()
}

internal fun attachmentLimitError(
    existing: List<MessagePart>,
    incoming: List<MessagePart>,
): String? = when {
    existing.size + incoming.size > MAX_COMPOSER_ATTACHMENTS ->
        "You can attach up to 4 images or files"
    incoming.any { attachmentSize(it) > MAX_COMPOSER_ATTACHMENT_BYTES } ->
        "Each attachment must be at most 5 MB"
    (existing + incoming).sumOf(::attachmentSize) > MAX_COMPOSER_TOTAL_BYTES ->
        "Attachments must total at most 6 MB"
    else -> null
}

internal fun attachmentSize(part: MessagePart): Int {
    if (!part.data.isEmpty) return part.data.size()
    val encoded = part.url.substringAfter(";base64,", "")
    if (encoded.isEmpty()) return 0
    val padding = encoded.takeLast(2).count { it == '=' }
    return (encoded.length * 3 / 4 - padding).coerceAtLeast(0)
}

internal fun attachmentDetails(part: MessagePart): String {
    val type = part.filename.substringAfterLast('.', "")
        .takeIf(String::isNotBlank)
        ?.uppercase(Locale.ROOT)
        ?: part.mediaType.substringAfter('/', "file").substringBefore('+').uppercase(Locale.ROOT)
    val bytes = attachmentSize(part)
    return if (bytes > 0) "$type · ${formatAttachmentSize(bytes)}" else type
}

internal fun formatAttachmentSize(bytes: Int): String = when {
    bytes >= 1024 * 1024 -> String.format(Locale.ROOT, "%.1f MB", bytes / (1024f * 1024f))
    bytes >= 1024 -> String.format(Locale.ROOT, "%.0f KB", bytes / 1024f)
    else -> "$bytes B"
}

internal fun decodeAttachmentBitmap(part: MessagePart, maxDimension: Int = 900): Bitmap? {
    if (!part.mediaType.startsWith("image/")) return null
    val bytes = when {
        !part.data.isEmpty -> part.data.toByteArray()
        part.url.contains(";base64,") -> runCatching {
            Base64.getDecoder().decode(part.url.substringAfter(";base64,"))
        }.getOrNull()
        else -> null
    } ?: return null
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    var sample = 1
    while (bounds.outWidth / sample > maxDimension * 2 || bounds.outHeight / sample > maxDimension * 2) {
        sample *= 2
    }
    return BitmapFactory.decodeByteArray(
        bytes,
        0,
        bytes.size,
        BitmapFactory.Options().apply { inSampleSize = sample },
    )
}
