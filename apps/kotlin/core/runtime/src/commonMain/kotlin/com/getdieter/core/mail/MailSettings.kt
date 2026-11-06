package com.getdieter.core.mail

import com.getdieter.client.v1.MailPreferences
import com.getdieter.core.platform.DeviceSettings

/**
 * This device's mail preferences, kept with the notification settings: a notification per new
 * message (on by default), only for important mail (off), and the unread count on the app icon
 * (off).
 */
object MailSettings {
    const val NOTIFY = "notifications.mail"
    const val NOTIFY_IMPORTANT_ONLY = "notifications.mail_important_only"
    const val APP_BADGE = "mail.app_badge"

    fun load(settings: DeviceSettings): MailPreferences {
        fun flag(key: String, default: Boolean) =
            settings.string(key)?.toBooleanStrictOrNull() ?: default
        return MailPreferences(
            notify = flag(NOTIFY, true),
            notify_important_only = flag(NOTIFY_IMPORTANT_ONLY, false),
            app_badge = flag(APP_BADGE, false),
        )
    }

    fun save(settings: DeviceSettings, preferences: MailPreferences) {
        settings.putString(NOTIFY, preferences.notify.toString())
        settings.putString(NOTIFY_IMPORTANT_ONLY, preferences.notify_important_only.toString())
        settings.putString(APP_BADGE, preferences.app_badge.toString())
    }
}
