package com.getdieter.mobile.share

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.text.Html
import com.getdieter.api.v1.MessagePart
import com.getdieter.core.composition.Attachments
import com.getdieter.mobile.platform.*
import com.getdieter.mobile.store.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

/** Reads Android share intents (text and files) into a new task. */
object AndroidShare {
    fun isShare(intent: Intent?): Boolean =
        intent?.action == Intent.ACTION_SEND || intent?.action == Intent.ACTION_SEND_MULTIPLE

    /** The shared text and files; files that cannot be read are reported, the rest still arrive. */
    suspend fun read(context: Context, intent: Intent): SharedItems {
        val text =
            intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
                ?: intent.getStringExtra(Intent.EXTRA_HTML_TEXT)?.let {
                    Html.fromHtml(it, Html.FROM_HTML_MODE_LEGACY).toString()
                }
                ?: intent.clipData
                    ?.let { clip ->
                        (0 until minOf(clip.itemCount, 5)).mapNotNull {
                            clip.getItemAt(it).text?.toString()
                        }
                    }
                    ?.joinToString("\n")
                    .orEmpty()
        val parts = mutableListOf<MessagePart>()
        var problem = ""
        for (uri in uris(intent)) {
            try {
                parts +=
                    withTimeout(30_000) {
                        withContext(Dispatchers.IO) {
                            readAttachmentPart(context, uri, imagesOnly = false)
                        }
                    }
            } catch (failure: Exception) {
                problem = failure.message ?: "A shared file could not be read. Choose it again."
            }
        }
        return SharedItems(text.trim(), parts, ShareDestination.NEW_TASK, problem)
    }

    /**
     * "Save to folder…": the shared files, unread, with their names; the core streams them into the
     * folder the person picks, so their size is not limited the way attachments are.
     */
    suspend fun readForFolder(context: Context, intent: Intent): SharedItems =
        withContext(Dispatchers.IO) {
            val files =
                uris(intent, limit = MAX_FOLDER_FILES)
                    .filter { it.scheme == "content" }
                    .map { uri ->
                        val name = runCatching {
                            context.contentResolver
                                .query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                                ?.use { if (it.moveToFirst()) it.getString(0) else null }
                        }
                            .getOrNull()
                        SharedFile(uri.toString(), name ?: uri.lastPathSegment.orEmpty())
                    }
            SharedItems(
                "",
                emptyList(),
                ShareDestination.FOLDER,
                if (files.isEmpty()) "Only files can be saved to a folder." else "",
                files,
            )
        }

    @Suppress("DEPRECATION")
    private fun uris(intent: Intent, limit: Int = Attachments.MAX_COUNT + 1): List<Uri> =
        buildList {
            if (intent.action == Intent.ACTION_SEND_MULTIPLE)
                addAll(intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty())
            else intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let(::add)
            intent.clipData?.let { clip ->
                repeat(minOf(clip.itemCount, 100)) { clip.getItemAt(it).uri?.let(::add) }
            }
        }
        .distinct()
        .take(limit)

    private const val MAX_FOLDER_FILES = 100
}
