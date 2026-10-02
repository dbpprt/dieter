package com.dbpprt.dieter.data

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit
import com.dbpprt.dieter.settings.AppPreferences
import com.dbpprt.dieter.widget.DieterWidgetPrefs
import com.dbpprt.dieter.widget.WidgetUsagePrefs
import java.io.File

/**
 * Deletes preference files, preference keys, and directories that nothing in
 * this app reads, so a device only keeps the state the app uses. Safe on
 * every start: each step does nothing once its target is gone. Runs off the
 * main thread.
 */
object UnusedStorage {
    /** Preference files without a reader; the core keeps that state in its own storage. */
    private val preferenceFiles = listOf("dieter_connection", "dieter_notification_state", "dieter_sync", "dieter_shared_kv", "dieter_conversation_drafts")

    fun clear(context: Context) {
        val appContext = context.applicationContext
        preferenceFiles.forEach(appContext::deleteSharedPreferences)
        File(appContext.filesDir, "global-sync").deleteRecursively()
        File(appContext.noBackupFilesDir, "task-capture").deleteRecursively()
        AppPreferences.preferences(appContext).retainKeys { AppPreferences.keeps(it) }
        DieterWidgetPrefs.preferences(appContext).retainKeys(DieterWidgetPrefs::keeps)
        WidgetUsagePrefs.preferences(appContext).retainKeys(WidgetUsagePrefs::keeps)
    }

    private fun SharedPreferences.retainKeys(keeps: (String) -> Boolean) {
        val unused = all.keys.filterNot(keeps)
        if (unused.isEmpty()) return
        edit { unused.forEach(::remove) }
    }
}
