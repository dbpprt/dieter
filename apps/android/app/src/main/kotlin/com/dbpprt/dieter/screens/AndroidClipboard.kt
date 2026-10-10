package com.dbpprt.dieter.screens

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import com.dbpprt.dieter.api.v1.RemoteDesktopClipboardItem
import com.dbpprt.dieter.core.screens.ClipboardContent
import com.dbpprt.dieter.core.screens.LocalClipboard
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import okio.ByteString.Companion.toByteString

/**
 * The Android pasteboard for screen clipboard sharing; the core owns the sync protocol and limits.
 * Paths never leave the device: remote files are staged privately and granted only through
 * [ScreenClipboardProvider].
 */
internal class AndroidClipboard(context: Context) : LocalClipboard {
    private val context = context.applicationContext
    private val clipboard = context.getSystemService(ClipboardManager::class.java)

    override fun stamp(): Long = clipboard.primaryClipDescription?.timestamp ?: 0

    override fun read(binary: Boolean): Pair<String, List<RemoteDesktopClipboardItem>>? {
        val clip = clipboard.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        if (clip.getItemAt(0).uri == null)
            return (clip.getItemAt(0).text?.toString() ?: return null) to emptyList()
        if (!binary) return null
        return "" to files(clip)
    }

    override fun apply(text: String, items: List<RemoteDesktopClipboardItem>) {
        ClipboardContent.validate(text, items)?.let { throw IllegalArgumentException(it) }
        val clip =
            if (items.isEmpty()) ClipData.newPlainText("Remote screen", text) else stage(items)
        clipboard.setPrimaryClip(clip)
    }

    private fun files(clip: ClipData): List<RemoteDesktopClipboardItem> {
        require(clip.itemCount <= ClipboardContent.MAX_ITEMS) {
            "Clipboard contains too many files"
        }
        var remaining = ClipboardContent.MAX_ITEM_BYTES
        return (0 until clip.itemCount).map { index ->
            val uri =
                requireNotNull(clip.getItemAt(index).uri) {
                    "Mixed clipboard formats are unsupported"
                }
            require(uri.scheme == "content") { "Clipboard files require a granted content URI" }
            val mime = context.contentResolver.getType(uri) ?: "application/octet-stream"
            val name =
                context.contentResolver
                    .query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                    ?.use { cursor ->
                        if (cursor.moveToFirst()) cursor.getString(0) else null
                    } ?: "Clipboard-$index"
            val data =
                context.contentResolver.openInputStream(uri)?.use { stream ->
                    val output = ByteArrayOutputStream()
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
            RemoteDesktopClipboardItem(
                name = name,
                mime_type = mime,
                data_ = data.toByteString(),
                kind =
                    if (clip.itemCount == 1 && mime in ClipboardContent.IMAGE_TYPES)
                        RemoteDesktopClipboardItem.Kind.IMAGE
                    else RemoteDesktopClipboardItem.Kind.FILE,
            )
        }
    }

    private fun stage(items: List<RemoteDesktopClipboardItem>): ClipData {
        val root = File(context.filesDir, "clipboard").apply { mkdirs() }
        synchronized(stagingLock) {
            val existing =
                root
                    .listFiles()
                    ?.filter { it.name.startsWith("transfer-") }
                    ?.sortedBy { it.name }
                    .orEmpty()
            existing.forEachIndexed { index, file ->
                if (
                    index < existing.size - 7 ||
                        System.currentTimeMillis() - file.lastModified() > 86_400_000
                )
                    file.deleteRecursively()
            }
            val batch = File(root, "transfer-${System.currentTimeMillis()}-${UUID.randomUUID()}")
            check(batch.mkdir()) { "Clipboard staging unavailable" }
            try {
                val uris = items.map { item ->
                    val file = File(batch, item.name)
                    file.outputStream().use { item.data_.write(it) }
                    FileProvider.getUriForFile(context, "${context.packageName}.clipboard", file)
                }
                return ClipData(
                        "Remote screen",
                        items
                            .map { it.mime_type.ifBlank { "application/octet-stream" } }
                            .distinct()
                            .toTypedArray(),
                        ClipData.Item(uris.first()),
                    )
                    .apply {
                        uris.drop(1).forEach { addItem(ClipData.Item(it)) }
                    }
            } catch (error: Exception) {
                batch.deleteRecursively()
                throw error
            }
        }
    }

    private companion object {
        val stagingLock = Any()
    }
}
