package com.dbpprt.dieter.settings

import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppPreferencesTest {
    @Test
    fun projectOrderPersistsInSequence() {
        val preferences = AppPreferences(InstrumentationRegistry.getInstrumentation().targetContext)
        val originalOrder = preferences.projectOrder.value
        val prefix = "project-order-test-${System.nanoTime()}"
        val expected = listOf("$prefix-c", "$prefix-a", "$prefix-b")

        try {
            preferences.setProjectOrder(expected + expected.first())

            assertEquals(expected, preferences.projectOrder.value)
            assertEquals(expected, AppPreferences(InstrumentationRegistry.getInstrumentation().targetContext).projectOrder.value)
        } finally {
            preferences.setProjectOrder(originalOrder)
        }
    }

    @Test
    fun pinnedChatOrderPersistsInSequence() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val preferences = AppPreferences(context)
        val originalOrder = preferences.pinnedChatOrder.value
        val prefix = "pinned-chat-order-test-${System.nanoTime()}"
        val expected = listOf("$prefix-c", "$prefix-a", "$prefix-b")

        try {
            preferences.setPinnedChatOrder(expected + expected.first())

            assertEquals(expected, preferences.pinnedChatOrder.value)
            assertEquals(expected, AppPreferences(context).pinnedChatOrder.value)
        } finally {
            preferences.setPinnedChatOrder(originalOrder)
        }
    }

    @Test
    fun boardNotificationPreferencePersistsPerBoard() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val enabledBoardId = "notification-test-${System.nanoTime()}"
        val untouchedBoardId = "$enabledBoardId-other"
        val preferences = AppPreferences(context)

        try {
            assertFalse(enabledBoardId in preferences.notificationBoardIds.value)
            assertFalse(untouchedBoardId in preferences.notificationBoardIds.value)

            preferences.setBoardNotificationsEnabled(enabledBoardId, true)

            assertTrue(enabledBoardId in preferences.notificationBoardIds.value)
            assertTrue(enabledBoardId in AppPreferences(context).notificationBoardIds.value)
            assertFalse(untouchedBoardId in preferences.notificationBoardIds.value)

            preferences.setBoardNotificationsEnabled(enabledBoardId, false)

            assertFalse(enabledBoardId in preferences.notificationBoardIds.value)
            assertFalse(enabledBoardId in AppPreferences(context).notificationBoardIds.value)
        } finally {
            preferences.setBoardNotificationsEnabled(enabledBoardId, false)
        }
    }

    @Test
    fun detailedNotificationSettingsPersistTogether() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val preferences = AppPreferences(context)
        val original = preferences.notificationSettings.value
        val expected = DieterNotificationSettings(
            activityNotificationsEnabled = false,
            runningChatsEnabled = false,
            successfulChatsEnabled = true,
            attentionChatsEnabled = false,
            reviewCardsEnabled = false,
            displayStyle = NotificationDisplayStyle.COMPACT,
            resultPreviewsEnabled = false,
            liveStatusActivityEnabled = false,
        )

        try {
            preferences.setNotificationSettings(expected)

            assertEquals(expected, preferences.notificationSettings.value)
            assertEquals(expected, AppPreferences(context).notificationSettings.value)
        } finally {
            preferences.setNotificationSettings(original)
        }
    }
}
