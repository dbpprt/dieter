package com.dbpprt.dieter.ui

import com.dbpprt.dieter.connection.BackgroundSyncMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BackgroundSyncSettingsTest {
    @Test
    fun modeCopyMakesPowerAndTimingTradeoffsExplicit() {
        assertEquals("Live", backgroundSyncModePresentation(BackgroundSyncMode.LIVE).first)
        assertTrue(backgroundSyncModePresentation(BackgroundSyncMode.LIVE).second.contains("highest battery"))
        assertEquals("Smart", backgroundSyncModePresentation(BackgroundSyncMode.PERIODIC).first)
        assertTrue(backgroundSyncModePresentation(BackgroundSyncMode.PERIODIC).second.contains("about every minute"))
        assertEquals("App only", backgroundSyncModePresentation(BackgroundSyncMode.APP_ONLY).first)
    }
}
