package com.dbpprt.dieter.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import com.dbpprt.dieter.api.v1.MessagePart
import okio.ByteString.Companion.toByteString
import com.dbpprt.dieter.core.composition.Attachments
import java.io.ByteArrayOutputStream
import java.util.Base64
import java.util.Locale


internal fun readAttachmentPart(context: Context, uri: Uri, imagesOnly: Boolean): MessagePart {
    require(uri.scheme == "content") { "Choose a file shared by an Android content provider" }
    val deadline = android.os.SystemClock.elapsedRealtime() + 30_000L
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
    require(declaredSize <= Attachments.MAX_FILE_BYTES || declaredSize < 0) {
        "Each attachment must be at most 5 MB"
    }
    val bytes = requireNotNull(resolver.openInputStream(uri)) { "Could not open attachment" }.use { input ->
        val output = ByteArrayOutputStream(
            declaredSize.takeIf { it in 1..Attachments.MAX_FILE_BYTES }?.toInt() ?: 32 * 1024,
        )
        val buffer = ByteArray(16 * 1024)
        var total = 0
        while (true) {
            check(!Thread.currentThread().isInterrupted && android.os.SystemClock.elapsedRealtime() < deadline) { "Reading the file timed out. Choose it again." }
            val read = input.read(buffer)
            if (read < 0) break
            total += read
            require(total <= Attachments.MAX_FILE_BYTES) { "Each attachment must be at most 5 MB" }
            output.write(buffer, 0, read)
        }
        output.toByteArray()
    }
    require(bytes.isNotEmpty()) { "Attachment is empty" }
    return Attachments.part(filename, mediaType, bytes.toByteString())
}

internal fun decodeAttachmentBitmap(part: MessagePart, maxDimension: Int = 900): Bitmap? {
    if (!part.media_type.startsWith("image/")) return null
    val bytes = when {
        part.data_.size > 0 -> part.data_.toByteArray()
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
