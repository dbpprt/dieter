package com.dbpprt.dieter.data

import android.content.Context
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.settings.AppPreferences
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UnusedStorageTest {
    @Test
    fun unusedFilesAndKeysGoWhileTheAppsOwnStateStays() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        context.getSharedPreferences("dieter_shared_kv", Context.MODE_PRIVATE).edit().putString("navigation", "{}").commit()
        val directory = File(context.noBackupFilesDir, "task-capture").apply { mkdirs() }
        File(directory, "draft.json").writeText("{}")
        val settings = AppPreferences.preferences(context)
        val palette = settings.getString("palette", null)
        settings.edit().putBoolean("show_reasoning_traces", true).putString("palette", "jade-operator").commit()
        try {
            UnusedStorage.clear(context)
            UnusedStorage.clear(context)

            assertTrue(context.getSharedPreferences("dieter_shared_kv", Context.MODE_PRIVATE).all.isEmpty())
            assertFalse(directory.exists())
            assertFalse(settings.contains("show_reasoning_traces"))
            assertEquals("jade-operator", settings.getString("palette", null))
        } finally {
            settings.edit().apply { if (palette == null) remove("palette") else putString("palette", palette) }.commit()
        }
    }
}
