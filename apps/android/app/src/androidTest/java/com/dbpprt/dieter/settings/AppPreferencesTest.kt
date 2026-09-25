package com.dbpprt.dieter.settings

import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.flow.first
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
    fun navigationUsesIsolatedAccountCacheAndDurableOfflineQueue() = runBlocking {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val prefix = "kv-test-${java.util.UUID.randomUUID()}-"
        val context = object : android.content.ContextWrapper(base) {
            override fun getApplicationContext(): android.content.Context = this
            override fun getSharedPreferences(name: String, mode: Int): android.content.SharedPreferences =
                base.getSharedPreferences(prefix + name, mode)
        }
        context.getSharedPreferences("dieter_shared_kv", 0).edit().putString("activeAccount", "fixture-account").commit()
        val preferences = withContext(Dispatchers.Main) { AppPreferences(context) }
        var restored: AppPreferences? = null
        var signedOut: AppPreferences? = null
        try {
            withContext(Dispatchers.Main) {
                preferences.setProjectOrder(listOf("c", "a", "b"))
                preferences.setPinnedProjectOrder(listOf("project-two", "project-one"))
                preferences.setPinnedChatOrder(listOf("two", "one"))
                preferences.setChatProjectCollapsed("p", true)
                preferences.setChatProjectExpanded("p", true)
            }
            preferences.sharedNavigation.awaitPendingWrites()
            val reloaded = withContext(Dispatchers.Main) { AppPreferences(context) }
            restored = reloaded
            withTimeout(5_000) {
                reloaded.sharedNavigation.status.first { it.pending == 9 }
                reloaded.projectOrder.first { it == listOf("c", "a", "b") }
                reloaded.pinnedProjectOrder.first { it == listOf("project-two", "project-one") }
                reloaded.pinnedChatOrder.first { it == listOf("two", "one") }
                reloaded.collapsedChatProjectIds.first { "p" in it }
                reloaded.expandedChatProjectIds.first { "p" in it }
            }
            withContext(Dispatchers.Main) {
                reloaded.setPinnedProjectOrder(listOf("project-one"))
            }
            reloaded.sharedNavigation.awaitPendingWrites()
            withTimeout(5_000) {
                reloaded.sharedNavigation.status.first { it.pending == 10 }
                reloaded.pinnedProjectOrder.first { it == listOf("project-one") }
            }
            reloaded.sharedNavigation.clearAccount()
            reloaded.sharedNavigation.awaitPendingWrites()
            val cleared = withContext(Dispatchers.Main) { AppPreferences(context) }
            signedOut = cleared
            cleared.sharedNavigation.awaitPendingWrites()
            assertTrue(cleared.projectOrder.value.isEmpty())
            assertTrue(cleared.pinnedProjectOrder.value.isEmpty())
            assertEquals(0, cleared.sharedNavigation.status.value.pending)
        } finally {
            preferences.sharedNavigation.close()
            restored?.sharedNavigation?.close()
            signedOut?.sharedNavigation?.close()
        }
        base.deleteSharedPreferences(prefix + "dieter_shared_kv")
        Unit
    }

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
