package com.dbpprt.dieter.settings

enum class NotificationDisplayStyle { COMPACT, DETAILED }

/** Device-local notification policy shared by the settings UI and background sync service. */
data class DieterNotificationSettings(
    val activityNotificationsEnabled: Boolean = true,
    val runningChatsEnabled: Boolean = true,
    val successfulChatsEnabled: Boolean = true,
    val attentionChatsEnabled: Boolean = true,
    val reviewCardsEnabled: Boolean = true,
    val displayStyle: NotificationDisplayStyle = NotificationDisplayStyle.DETAILED,
    val resultPreviewsEnabled: Boolean = true,
    val liveStatusActivityEnabled: Boolean = true,
)
