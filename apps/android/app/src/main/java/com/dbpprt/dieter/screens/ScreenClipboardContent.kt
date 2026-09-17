package com.dbpprt.dieter.screens

import android.content.ClipData
import android.content.Context
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import com.dbpprt.dieter.v1.RemoteDesktopClipboardItem
import com.dbpprt.dieter.v1.RemoteDesktopClipboardResponse
import com.google.protobuf.ByteString
import java.io.File
import java.util.UUID

/** Paths never leave the source device. FileProvider grants only staged clipboard files. */
internal data class ScreenClipboardContent(val text: String? = null, val items: List<RemoteDesktopClipboardItem> = emptyList()) {
    fun validate() {
        require((text?.toByteArray()?.size ?: 0) <= ScreenClipboard.LIMIT && items.size <= 64 &&
            items.sumOf { it.data.size().toLong() } <= BINARY_LIMIT && (text == null || items.isEmpty())) { "Clipboard limit: 1 MiB text or 8 MiB across 64 files" }
        val names = HashSet<String>()
        items.forEach {
            require(it.name.isNotBlank() && it.name.toByteArray().size <= 255 && it.name !in listOf(".", "..") &&
                it.name.none { ch -> ch == '/' || ch == '\\' || ch == '\u0000' } && names.add(java.text.Normalizer.normalize(it.name, java.text.Normalizer.Form.NFC).lowercase(java.util.Locale.ROOT)) && it.mimeType.length <= 128 &&
                (it.kind == RemoteDesktopClipboardItem.Kind.FILE || (it.kind == RemoteDesktopClipboardItem.Kind.IMAGE && items.size == 1 && it.mimeType in IMAGE_TYPES))) { "Invalid clipboard file or image" }
        }
    }
    fun clip(context: Context): ClipData? {
        validate()
        text?.let { return ClipData.newPlainText("Remote screen", it) }
        if (items.isEmpty()) return null
        val root = File(context.filesDir, "clipboard").apply { mkdirs() }
        synchronized(stagingLock) {
            val existing = root.listFiles()?.filter { it.name.startsWith("transfer-") }?.sortedBy { it.name }.orEmpty()
            existing.forEachIndexed { index, file ->
                if (index < existing.size - 7 || System.currentTimeMillis() - file.lastModified() > 86_400_000) file.deleteRecursively()
            }
            val batch = File(root, "transfer-${System.currentTimeMillis()}-${UUID.randomUUID()}")
            check(batch.mkdir()) { "Clipboard staging unavailable" }
            try {
                val uris = items.map { item ->
                    val file = File(batch, item.name)
                    file.outputStream().use { item.data.writeTo(it) }
                    FileProvider.getUriForFile(context, "${context.packageName}.clipboard", file)
                }
                return ClipData("Remote screen", items.map { it.mimeType.ifBlank { "application/octet-stream" } }.distinct().toTypedArray(), ClipData.Item(uris.first())).apply {
                    uris.drop(1).forEach { addItem(ClipData.Item(it)) }
                }
            } catch (error: Exception) { batch.deleteRecursively(); throw error }
        }
    }
    companion object {
        const val BINARY_LIMIT = 8 * 1024 * 1024
        private val IMAGE_TYPES = setOf("image/png", "image/jpeg", "image/tiff", "image/webp")
        private val stagingLock = Any()
        fun response(value: RemoteDesktopClipboardResponse) = ScreenClipboardContent(if (value.hasText) value.text else null, value.itemsList)
        fun read(context: Context, clip: ClipData?, binary: Boolean): ScreenClipboardContent {
            if (clip == null || clip.itemCount == 0) return ScreenClipboardContent()
            if (clip.getItemAt(0).uri == null) return ScreenClipboardContent(clip.getItemAt(0).text?.toString()).also { it.validate() }
            if (!binary) return ScreenClipboardContent()
            require(clip.itemCount <= 64) { "Clipboard contains too many files" }
            var remaining = BINARY_LIMIT
            val items = (0 until clip.itemCount).map { index ->
                val uri = requireNotNull(clip.getItemAt(index).uri) { "Mixed clipboard formats are unsupported" }
                require(uri.scheme == "content") { "Clipboard files require a granted content URI" }
                val mime = context.contentResolver.getType(uri) ?: "application/octet-stream"
                val name = context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) cursor.getString(0) else null
                } ?: "Clipboard-$index"
                val data = context.contentResolver.openInputStream(uri)?.use { stream ->
                    val output = java.io.ByteArrayOutputStream()
                    val buffer = ByteArray(16 * 1024)
                    while (true) {
                        val count = stream.read(buffer, 0, minOf(buffer.size, remaining + 1))
                        if (count < 0) break
                        remaining -= count
                        require(remaining >= 0) { "Clipboard files exceed 8 MiB" }
                        output.write(buffer, 0, count)
                    }
                    output.toByteArray()
                } ?: error("Clipboard file unavailable")
                RemoteDesktopClipboardItem.newBuilder().setName(name).setMimeType(mime)
                    .setKind(if (clip.itemCount == 1 && mime in IMAGE_TYPES) RemoteDesktopClipboardItem.Kind.IMAGE else RemoteDesktopClipboardItem.Kind.FILE)
                    .setData(ByteString.copyFrom(data)).build()
            }
            return ScreenClipboardContent(items = items).also { it.validate() }
        }
    }
}
