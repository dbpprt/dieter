package com.dbpprt.dieter.mobile

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.text.Html
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.core.composition.Attachments
import com.dbpprt.dieter.ui.readAttachmentPart
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

    @Suppress("DEPRECATION")
    private fun uris(intent: Intent): List<Uri> = buildList {
        if (intent.action == Intent.ACTION_SEND_MULTIPLE)
            addAll(intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty())
        else intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let(::add)
        intent.clipData?.let { clip ->
            repeat(minOf(clip.itemCount, 100)) { clip.getItemAt(it).uri?.let(::add) }
        }
    }
        .distinct()
        .take(Attachments.MAX_COUNT + 1)
}
