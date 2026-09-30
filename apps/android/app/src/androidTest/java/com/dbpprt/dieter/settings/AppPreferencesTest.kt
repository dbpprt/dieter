package com.dbpprt.dieter.settings

import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.core.notifications.NotificationSettings
import com.dbpprt.dieter.core.notifications.NotificationStyle
import com.dbpprt.dieter.sharedcore.SharedCore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppPreferencesTest {
    @Test
    fun splitPaneWidthsPersistIndependentlyAcrossInstances() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val preferences = AppPreferences(context)
        val originalChatsFraction = preferences.chatsPaneLeadingFraction.value
        val originalActivityFraction = preferences.activityPaneLeadingFraction.value
        val originalProjectsFraction = preferences.projectsPaneLeadingFraction.value
        val originalBoardFraction = preferences.boardPaneLeadingFraction.value

        try {
            preferences.setChatsPaneLeadingFraction(0.31f)
            preferences.setActivityPaneLeadingFraction(0.29f)
            preferences.setProjectsPaneLeadingFraction(0.36f)
            preferences.setBoardPaneLeadingFraction(0.57f)

            val restored = AppPreferences(context)
            assertEquals(0.31f, restored.chatsPaneLeadingFraction.value, 0.0001f)
            assertEquals(0.29f, restored.activityPaneLeadingFraction.value, 0.0001f)
            assertEquals(0.36f, restored.projectsPaneLeadingFraction.value, 0.0001f)
            assertEquals(0.57f, restored.boardPaneLeadingFraction.value, 0.0001f)
        } finally {
            preferences.setChatsPaneLeadingFraction(originalChatsFraction)
            preferences.setActivityPaneLeadingFraction(originalActivityFraction)
            preferences.setProjectsPaneLeadingFraction(originalProjectsFraction)
            preferences.setBoardPaneLeadingFraction(originalBoardFraction)
        }
    }

    @Test
    fun boardNotificationPreferencePersistsPerBoard() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val settings = SharedCore.settings(context)
        val original = NotificationSettings.load(settings)
        val enabledBoardId = "notification-test-${System.nanoTime()}"
        val untouchedBoardId = "$enabledBoardId-other"
        try {
            assertFalse(enabledBoardId in original.boardIds)
            original.copy(boardIds = original.boardIds + enabledBoardId).save(settings)
            val reloaded = NotificationSettings.load(SharedCore.settings(context))
            assertTrue(enabledBoardId in reloaded.boardIds)
            assertFalse(untouchedBoardId in reloaded.boardIds)
            reloaded.copy(boardIds = reloaded.boardIds - enabledBoardId).save(settings)
            assertFalse(enabledBoardId in NotificationSettings.load(SharedCore.settings(context)).boardIds)
        } finally {
            original.save(settings)
        }
    }

    @Test
    fun detailedNotificationSettingsPersistTogether() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val settings = SharedCore.settings(context)
        val original = NotificationSettings.load(settings)
        val expected = NotificationSettings(
            enabled = false,
            runningChats = false,
            successfulChats = true,
            attentionChats = false,
            reviewCards = false,
            style = NotificationStyle.COMPACT,
            resultPreviews = false,
            liveStatus = false,
            boardIds = original.boardIds,
        )
        try {
            expected.save(settings)
            // The core reads these through Android's device settings in every process.
            assertEquals(expected, NotificationSettings.load(SharedCore.settings(context)))
        } finally {
            original.save(settings)
        }
    }
}
