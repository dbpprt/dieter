package com.dbpprt.dieter.core.composition

import com.dbpprt.dieter.api.v1.MessagePart
import okio.ByteString

/**
 * The daemon's attachment limits and naming rules, enforced before anything
 * is queued. Reading file bytes stays native; this decides what is allowed.
 */
object Attachments {
    const val MAX_COUNT = 4
    const val MAX_FILE_BYTES = 5L * 1024 * 1024
    const val MAX_TOTAL_BYTES = 6L * 1024 * 1024
    const val OCTET_STREAM = "application/octet-stream"

    /** The limits, as shown next to attachment pickers. */
    const val LIMITS = "Up to 4 attachments · 5 MB each · 6 MB total"

    private val extensions = mapOf(
        "png" to "image/png", "jpg" to "image/jpeg", "jpeg" to "image/jpeg", "gif" to "image/gif", "webp" to "image/webp",
        "heic" to "image/heic", "heif" to "image/heif", "bmp" to "image/bmp", "tif" to "image/tiff", "tiff" to "image/tiff",
        "svg" to "image/svg+xml", "pdf" to "application/pdf", "txt" to "text/plain", "md" to "text/markdown",
        "json" to "application/json", "csv" to "text/csv", "html" to "text/html", "xml" to "application/xml",
        "zip" to "application/zip", "log" to "text/plain", "yaml" to "application/yaml", "yml" to "application/yaml",
    )

    /** Bytes the daemon will receive: the data, or the decoded size of a base64 data URL. */
    fun size(part: MessagePart): Long {
        if (part.data_.size > 0) return part.data_.size.toLong()
        val url = part.url
        if (!url.startsWith("data:")) return 0
        val payload = url.substringAfter(',', "")
        if (!url.substringBefore(',').endsWith(";base64")) return payload.length.toLong()
        val padding = payload.takeLast(2).count { it == '=' }
        return (payload.length.toLong() * 3 / 4 - padding).coerceAtLeast(0)
    }

    /** The first limit [parts] would break, or null. Checked in the order count, file size, total size. */
    fun limitError(parts: List<MessagePart>): String? {
        if (parts.size > MAX_COUNT) return "You can attach up to 4 images or files."
        parts.firstOrNull { it.data_.size == 0 && it.url.isEmpty() }?.let { return "${it.filename.ifEmpty { "The attachment" }} is empty." }
        parts.firstOrNull { size(it) > MAX_FILE_BYTES }?.let { return "Each attachment must be at most 5 MB." }
        if (parts.sumOf(::size) > MAX_TOTAL_BYTES) return "Attachments must total at most 6 MB."
        return null
    }

    /** A media type the daemon accepts: lowercase, without parameters, else guessed from the name. */
    fun mediaType(declared: String?, filename: String): String {
        val normalized = declared?.substringBefore(';')?.trim()?.lowercase().orEmpty()
        if (normalized.contains('/') && !normalized.startsWith('/') && !normalized.endsWith('/')) return normalized
        return extensions[filename.substringAfterLast('.', "").lowercase()] ?: OCTET_STREAM
    }

    /** A base name without directories; empty names get a readable default. */
    fun filename(raw: String?, mediaType: String): String {
        val base = raw.orEmpty().replace('\\', '/').substringAfterLast('/').trim()
        if (base.isNotEmpty() && base != "." && base != "..") return base
        return if (mediaType.startsWith("image/")) "attached-image" else "attachment"
    }

    /** The message part for a file the platform has read. */
    fun part(filename: String?, declaredMediaType: String?, bytes: ByteString): MessagePart {
        val name = filename.orEmpty()
        val mediaType = mediaType(declaredMediaType, name)
        return MessagePart(type = "file", media_type = mediaType, filename = filename(name, mediaType), data_ = bytes)
    }

    /** Appends [added] when the result stays within limits; otherwise returns the error. */
    fun appending(existing: List<MessagePart>, added: List<MessagePart>): Result<List<MessagePart>> {
        val combined = existing + added
        return limitError(combined)?.let { Result.failure(IllegalArgumentException(it)) } ?: Result.success(combined)
    }

    /** Parts sent for a composer: the trimmed text first, then attachments. */
    fun messageParts(text: String, attachments: List<MessagePart>): List<MessagePart> = buildList {
        text.trim().takeIf { it.isNotEmpty() }?.let { add(MessagePart(type = "text", text = it)) }
        addAll(attachments)
    }

    /** A short kind for display, e.g. "PDF" or "PNG image"; formatting sizes stays native. */
    /** "PNG · 1.2 MB": the file's type and size, for an attachment chip. */
    fun details(part: MessagePart): String {
        val type = part.filename.substringAfterLast('.', "").ifBlank { null }?.uppercase()
            ?: part.media_type.substringAfter('/', "file").substringBefore('+').uppercase()
        val bytes = size(part)
        return if (bytes > 0) "$type · ${com.dbpprt.dieter.core.presentation.ByteSizes.format(bytes)}" else type
    }

    fun kind(part: MessagePart): String {
        val extension = part.filename.substringAfterLast('.', "").uppercase()
        return when {
            part.media_type.startsWith("image/") -> if (extension.isNotEmpty()) "$extension image" else "Image"
            extension.isNotEmpty() -> extension
            else -> "File"
        }
    }
}
