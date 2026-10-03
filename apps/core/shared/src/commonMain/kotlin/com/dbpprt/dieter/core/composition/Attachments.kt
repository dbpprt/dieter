package com.dbpprt.dieter.core.composition

import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.core.presentation.ByteSizes
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

    private const val MIB = 1024L * 1024

    /** The limits, as shown next to attachment pickers. */
    val LIMITS = "Up to $MAX_COUNT attachments · ${MAX_FILE_BYTES / MIB} MB each · ${MAX_TOTAL_BYTES / MIB} MB total"

    // What the platforms' type systems (UTType, MimeTypeMap) report for common
    // files, so a file without a declared type gets the same one everywhere.
    private val extensions = mapOf(
        "png" to "image/png", "jpg" to "image/jpeg", "jpeg" to "image/jpeg", "gif" to "image/gif", "webp" to "image/webp",
        "heic" to "image/heic", "heif" to "image/heif", "bmp" to "image/bmp", "tif" to "image/tiff", "tiff" to "image/tiff",
        "avif" to "image/avif", "svg" to "image/svg+xml", "pdf" to "application/pdf", "txt" to "text/plain", "md" to "text/markdown",
        "json" to "application/json", "csv" to "text/csv", "tsv" to "text/tab-separated-values", "html" to "text/html",
        "htm" to "text/html", "css" to "text/css", "js" to "text/javascript", "xml" to "application/xml", "rtf" to "text/rtf",
        "zip" to "application/zip", "gz" to "application/gzip", "tar" to "application/x-tar", "log" to "text/plain",
        "yaml" to "application/yaml", "yml" to "application/yaml", "mov" to "video/quicktime", "mp4" to "video/mp4",
        "m4v" to "video/x-m4v", "mp3" to "audio/mpeg", "m4a" to "audio/mp4", "wav" to "audio/wav",
        "doc" to "application/msword", "docx" to "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls" to "application/vnd.ms-excel", "xlsx" to "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt" to "application/vnd.ms-powerpoint", "pptx" to "application/vnd.openxmlformats-officedocument.presentationml.presentation",
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

    /** The first limit [parts] would break, or null. Checked in the order count, emptiness, file size, total size. */
    fun limitError(parts: List<MessagePart>): String? {
        if (parts.size > MAX_COUNT) return TOO_MANY
        parts.firstOrNull { it.data_.size == 0 && it.url.isEmpty() }?.let { return empty(it.filename) }
        parts.firstOrNull { size(it) > MAX_FILE_BYTES }?.let { return FILE_TOO_LARGE }
        if (parts.sumOf(::size) > MAX_TOTAL_BYTES) return TOTAL_TOO_LARGE
        return null
    }

    /**
     * The same check over files the platform has measured but not read yet:
     * [names] and [sizes] pair up by index, and a size of zero or less is an
     * empty file.
     */
    fun limitError(names: List<String>, sizes: List<Long>): String? {
        if (sizes.size > MAX_COUNT) return TOO_MANY
        val emptyIndex = sizes.indexOfFirst { it <= 0 }
        if (emptyIndex >= 0) return empty(names.getOrNull(emptyIndex).orEmpty())
        if (sizes.any { it > MAX_FILE_BYTES }) return FILE_TOO_LARGE
        if (sizes.sum() > MAX_TOTAL_BYTES) return TOTAL_TOO_LARGE
        return null
    }

    val TOO_MANY = "You can attach up to $MAX_COUNT images or files."

    /** Also what a platform says when it stops reading a file past [MAX_FILE_BYTES]. */
    val FILE_TOO_LARGE = "Each attachment must be at most ${MAX_FILE_BYTES / MIB} MB."
    val TOTAL_TOO_LARGE = "Attachments must total at most ${MAX_TOTAL_BYTES / MIB} MB."

    /** How many more files may join [count] attached ones. */
    fun remainingSlots(count: Int): Int = (MAX_COUNT - count).coerceAtLeast(0)

    private fun empty(filename: String) = "${filename.ifEmpty { "The attachment" }} is empty."

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

    /** "PNG · 1.2 MB": the file's type and size, for an attachment chip. */
    fun details(part: MessagePart): String = details(part.filename, part.media_type, size(part))

    /**
     * "PNG · 1.2 MB": the type from [filename]'s extension, else from
     * [mediaType] ("image/svg+xml" reads "SVG"); [bytes] are left out when
     * there are none.
     */
    fun details(filename: String, mediaType: String, bytes: Long): String {
        val type = filename.substringAfterLast('.', "").ifBlank { null }?.uppercase()
            ?: mediaType.substringAfter('/', "file").substringBefore('+').uppercase()
        return if (bytes > 0) "$type · ${ByteSizes.format(bytes)}" else type
    }
}
