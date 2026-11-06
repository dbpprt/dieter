package com.getdieter.mobile.platform

import android.app.Activity
import android.content.Intent
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext

/** `ACTION_SEND` with Markdown text and its subject, through the system chooser. */
@Composable
internal actual fun rememberTextSharer(): (subject: String, text: String) -> Unit {
    val context = LocalContext.current
    return remember(context) {
        { subject, text ->
            val send =
                Intent(Intent.ACTION_SEND).apply {
                    type = "text/markdown"
                    putExtra(Intent.EXTRA_SUBJECT, subject)
                    putExtra(Intent.EXTRA_TITLE, subject)
                    putExtra(Intent.EXTRA_TEXT, text)
                }
            val chooser = Intent.createChooser(send, subject)
            if (context !is Activity) chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(chooser)
        }
    }
}
