package com.dbpprt.nauclio.settings

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
}
