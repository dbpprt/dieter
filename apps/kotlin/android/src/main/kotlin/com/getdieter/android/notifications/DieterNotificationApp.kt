package com.getdieter.android.notifications

import android.app.Application
import android.content.Context
import com.getdieter.android.BuildConfig
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions

class DieterNotificationApp : Application() {
    override fun onCreate() {
        super.onCreate()
        AndroidNotifications.createChannel(this)
        if (configured(this) && FirebaseApp.getApps(this).isEmpty()) {
            FirebaseApp.initializeApp(
                this,
                FirebaseOptions.Builder()
                    .setApplicationId(BuildConfig.FCM_APPLICATION_ID)
                    .setApiKey(BuildConfig.FCM_API_KEY)
                    .setProjectId(BuildConfig.FCM_PROJECT_ID)
                    .setGcmSenderId(BuildConfig.FCM_SENDER_ID)
                    .build(),
            )
        }
    }

    companion object {
        fun configured(context: Context): Boolean =
            !context.packageName.endsWith(".e2e") &&
                listOf(
                        BuildConfig.FCM_APPLICATION_ID,
                        BuildConfig.FCM_API_KEY,
                        BuildConfig.FCM_PROJECT_ID,
                        BuildConfig.FCM_SENDER_ID,
                    )
                    .all { it.isNotBlank() }
    }
}
