package com.dbpprt.dieter.settings

import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppPreferencesTest {
    @Test
    fun conversationCreationPreferencesPersistTogether() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val preferences = AppPreferences(context)
        val original = preferences.conversationCreation.value
        val expected = ConversationCreationPreferences(
            provider = "codex",
            model = "sol",
            effort = "xhigh",
            workspaceMode = "project",
        )

        try {
            preferences.setConversationCreationPreferences(expected)

            assertEquals(expected, preferences.conversationCreation.value)
            assertEquals(expected, AppPreferences(context).conversationCreation.value)
        } finally {
            preferences.setConversationCreationPreferences(original)
        }
    }

    @Test
    fun navigationUsesIsolatedAccountCacheAndDurableOfflineQueue() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val prefix = "kv-test-${java.util.UUID.randomUUID()}-"
        val context = object : android.content.ContextWrapper(base) {
            override fun getApplicationContext(): android.content.Context = this
            override fun getSharedPreferences(name: String, mode: Int): android.content.SharedPreferences =
                base.getSharedPreferences(prefix + name, mode)
        }
        context.getSharedPreferences("dieter_shared_kv", 0).edit().putString("activeAccount", "fixture-account").commit()
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val preferences = AppPreferences(context)
            preferences.setProjectOrder(listOf("c", "a", "b"))
            preferences.setPinnedChatOrder(listOf("two", "one"))
            preferences.setChatProjectCollapsed("p", true)
            preferences.setChatProjectExpanded("p", true)
            val restored = AppPreferences(context)
            assertEquals(listOf("c", "a", "b"), restored.projectOrder.value)
            assertEquals(listOf("two", "one"), restored.pinnedChatOrder.value)
            assertTrue("p" in restored.collapsedChatProjectIds.value)
            assertTrue("p" in restored.expandedChatProjectIds.value)
            assertEquals(7, restored.sharedNavigation.status.value.pending)
            restored.sharedNavigation.clearAccount()
            val signedOut = AppPreferences(context)
            assertTrue(signedOut.projectOrder.value.isEmpty())
            assertEquals(0, signedOut.sharedNavigation.status.value.pending)
        }
        base.deleteSharedPreferences(prefix + "dieter_shared_kv")
    }

    @Test
    fun splitPaneWidthsPersistIndependentlyAcrossInstances() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val preferences = AppPreferences(context)
        val originalChatsFraction = preferences.chatsPaneLeadingFraction.value
        val originalBoardFraction = preferences.boardPaneLeadingFraction.value

        try {
            preferences.setChatsPaneLeadingFraction(0.31f)
            preferences.setBoardPaneLeadingFraction(0.57f)

            val restored = AppPreferences(context)
            assertEquals(0.31f, restored.chatsPaneLeadingFraction.value, 0.0001f)
            assertEquals(0.57f, restored.boardPaneLeadingFraction.value, 0.0001f)
        } finally {
            preferences.setChatsPaneLeadingFraction(originalChatsFraction)
            preferences.setBoardPaneLeadingFraction(originalBoardFraction)
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
